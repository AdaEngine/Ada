#include "CEditorTerminal.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#define _WIN32_WINNT 0x0A00
#include <windows.h>
struct AdaTerminal { HPCON console; HANDLE input, output, process, job; };
static wchar_t *wide(const char *text) {
    int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, NULL, 0);
    if (!count) return NULL;
    wchar_t *result = calloc(count, sizeof(wchar_t));
    if (result) MultiByteToWideChar(CP_UTF8, 0, text, -1, result, count);
    return result;
}
AdaTerminal *ada_terminal_open(const char *directory, int columns, int rows, char *error, size_t capacity) {
    AdaTerminal *t = calloc(1, sizeof(*t));
    if (!t) return NULL;
    HANDLE in = NULL, out = NULL;
    STARTUPINFOEXW startup = {0};
    PROCESS_INFORMATION process = {0};
    int attributesReady = 0;
    wchar_t *cwd = wide(directory);
    wchar_t shell[MAX_PATH];
    DWORD length = GetEnvironmentVariableW(L"ComSpec", shell, MAX_PATH);
    if (!length || length >= MAX_PATH) wcscpy_s(shell, MAX_PATH, L"C:\\Windows\\System32\\cmd.exe");
    wchar_t command[MAX_PATH + 16];
    swprintf_s(command, MAX_PATH + 16, L"\"%ls\" /Q", shell);
    if (!cwd || !CreatePipe(&in, &t->input, NULL, 65536) || !CreatePipe(&t->output, &out, NULL, 65536)) goto fail;
    DWORD pipeMode = PIPE_NOWAIT;
    if (!SetNamedPipeHandleState(t->input, &pipeMode, NULL, NULL)) goto fail;
    COORD size = {(SHORT)columns, (SHORT)rows};
    HRESULT result = CreatePseudoConsole(size, in, out, 0, &t->console);
    if (FAILED(result)) { SetLastError((DWORD)result); goto fail; }
    CloseHandle(in); in = NULL; CloseHandle(out); out = NULL;
    SIZE_T attributeSize = 0;
    InitializeProcThreadAttributeList(NULL, 1, 0, &attributeSize);
    startup.lpAttributeList = malloc(attributeSize);
    if (!startup.lpAttributeList || !InitializeProcThreadAttributeList(startup.lpAttributeList, 1, 0, &attributeSize)) goto fail;
    attributesReady = 1;
    if (!UpdateProcThreadAttribute(startup.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
                                  t->console, sizeof(HPCON), NULL, NULL)) goto fail;
    startup.StartupInfo.cb = sizeof(startup);
    // Let ConPTY provide console handles; never inherit the editor's redirected stdio.
    startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    if (!CreateProcessW(shell, command, NULL, NULL, FALSE, EXTENDED_STARTUPINFO_PRESENT | CREATE_SUSPENDED,
                        NULL, cwd, &startup.StartupInfo, &process)) goto fail;
    t->process = process.hProcess;
    t->job = CreateJobObjectW(NULL, NULL);
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!t->job || !SetInformationJobObject(t->job, JobObjectExtendedLimitInformation, &limits, sizeof(limits))
        || !AssignProcessToJobObject(t->job, t->process)) {
        TerminateProcess(t->process, 1); CloseHandle(process.hThread); goto fail;
    }
    ResumeThread(process.hThread); CloseHandle(process.hThread);
    DeleteProcThreadAttributeList(startup.lpAttributeList); free(startup.lpAttributeList); free(cwd);
    return t;
fail:
    snprintf(error, capacity, "Windows terminal error %lu", GetLastError());
    if (startup.lpAttributeList) { if (attributesReady) DeleteProcThreadAttributeList(startup.lpAttributeList); free(startup.lpAttributeList); }
    free(cwd);
    if (in) CloseHandle(in);
    if (out) CloseHandle(out);
    ada_terminal_close(t);
    return NULL;
}
int ada_terminal_read(AdaTerminal *t, uint8_t *bytes, int capacity) {
    DWORD available = 0, count = 0;
    if (!PeekNamedPipe(t->output, NULL, 0, NULL, &available, NULL)) return -1;
    if (!available) return WaitForSingleObject(t->process, 0) == WAIT_OBJECT_0 ? -1 : 0;
    if (!ReadFile(t->output, bytes, available < (DWORD)capacity ? available : (DWORD)capacity, &count, NULL)) return -1;
    return (int)count;
}
int ada_terminal_write(AdaTerminal *t, const uint8_t *bytes, int count) {
    DWORD written = 0;
    if (WriteFile(t->input, bytes, (DWORD)count, &written, NULL)) return (int)written;
    DWORD error = GetLastError();
    return error == ERROR_NO_DATA || error == ERROR_PIPE_BUSY ? 0 : -1;
}
int ada_terminal_resize(AdaTerminal *t, int columns, int rows) {
    COORD size = {(SHORT)columns, (SHORT)rows};
    return SUCCEEDED(ResizePseudoConsole(t->console, size)) ? 0 : -1;
}
void ada_terminal_close(AdaTerminal *t) {
    if (!t) return;
    if (t->job) { TerminateJobObject(t->job, 0); CloseHandle(t->job); }
    if (t->process) { TerminateProcess(t->process, 0); CloseHandle(t->process); }
    // Close our read end before ConPTY teardown, so its final writes cannot wait for a reader.
    if (t->input) CloseHandle(t->input);
    if (t->output) CloseHandle(t->output);
    if (t->console) ClosePseudoConsole(t->console);
    free(t);
}
#elif defined(__APPLE__) || (defined(__linux__) && !defined(__ANDROID__))
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <pthread.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <TargetConditionals.h>
#include <util.h>
#else
#include <pty.h>
#endif
struct AdaTerminal { int master; pid_t pid; };
AdaTerminal *ada_terminal_open(const char *directory, int columns, int rows, char *error, size_t capacity) {
#if defined(__APPLE__) && !TARGET_OS_OSX
    snprintf(error, capacity, "Local shells are unavailable on this platform"); return NULL;
#else
    AdaTerminal *t = calloc(1, sizeof(*t));
    if (!t) return NULL;
    t->master = -1;
    const char *shell = getenv("SHELL");
    if (!shell || shell[0] != '/') shell = "/bin/sh";
    // Allocate everything before fork without changing the editor's process-wide environment.
    extern char **environ;
    size_t environmentCount = 0;
    while (environ[environmentCount]) environmentCount++;
    char **environment = calloc(environmentCount + 3, sizeof(char *));
    if (!environment) { free(t); return NULL; }
    size_t destination = 0;
    for (size_t i = 0; i < environmentCount; i++)
        if (strncmp(environ[i], "TERM=", 5) && strncmp(environ[i], "COLORTERM=", 10)) environment[destination++] = environ[i];
    environment[destination++] = "TERM=xterm-256color";
    environment[destination] = "COLORTERM=truecolor";
    struct winsize size = {0}; size.ws_col = columns; size.ws_row = rows;
    t->pid = forkpty(&t->master, NULL, NULL, &size);
    if (t->pid == 0) {
        if (chdir(directory) != 0) _exit(126);
        execle(shell, shell, "-l", (char *)NULL, environment);
        _exit(127);
    }
    free(environment);
    if (t->pid < 0) { snprintf(error, capacity, "%s", strerror(errno)); free(t); return NULL; }
    fcntl(t->master, F_SETFL, fcntl(t->master, F_GETFL) | O_NONBLOCK);
    fcntl(t->master, F_SETFD, FD_CLOEXEC);
    return t;
#endif
}
int ada_terminal_read(AdaTerminal *t, uint8_t *bytes, int capacity) {
    ssize_t count = read(t->master, bytes, capacity);
    if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) return 0;
    return count > 0 ? (int)count : -1;
}
int ada_terminal_write(AdaTerminal *t, const uint8_t *bytes, int count) {
    ssize_t written = write(t->master, bytes, count);
    if (written < 0 && (errno == EAGAIN || errno == EINTR)) return 0;
    return (int)written;
}
int ada_terminal_resize(AdaTerminal *t, int columns, int rows) {
    struct winsize size = {0}; size.ws_col = columns; size.ws_row = rows;
    return ioctl(t->master, TIOCSWINSZ, &size);
}
static void *reap(void *context) {
    AdaTerminal *t = context;
    while (waitpid(t->pid, NULL, 0) < 0 && errno == EINTR) {}
    free(t);
    return NULL;
}
void ada_terminal_close(AdaTerminal *t) {
    if (!t) return;
    if (t->master >= 0) close(t->master);
    if (t->pid > 0) {
        kill(-t->pid, SIGHUP);
        if (waitpid(t->pid, NULL, WNOHANG) == 0) {
            kill(-t->pid, SIGKILL);
            // Transfer ownership to a reaper so closing a tab never blocks the UI.
            pthread_t thread;
            if (pthread_create(&thread, NULL, reap, t) == 0) { pthread_detach(thread); return; }
            while (waitpid(t->pid, NULL, 0) < 0 && errno == EINTR) {}
        }
    }
    free(t);
}
#else
struct AdaTerminal { int unused; };
AdaTerminal *ada_terminal_open(const char *d, int c, int r, char *e, size_t n) { snprintf(e, n, "Local shells are unavailable on this platform"); return NULL; }
int ada_terminal_read(AdaTerminal *t, uint8_t *b, int n) { return -1; }
int ada_terminal_write(AdaTerminal *t, const uint8_t *b, int n) { return -1; }
int ada_terminal_resize(AdaTerminal *t, int c, int r) { return -1; }
void ada_terminal_close(AdaTerminal *t) {}
#endif
