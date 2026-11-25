#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0A00
#include <windows.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

static volatile LONG editor_process_id;

static BOOL WINAPI handle_interrupt(DWORD event) {
    if (event != CTRL_C_EVENT && event != CTRL_BREAK_EVENT) {
        return FALSE;
    }
    DWORD process_id = (DWORD)InterlockedCompareExchange(&editor_process_id, 0, 0);
    if (process_id == 0) {
        return FALSE;
    }
    // Let the default handler stop a launch that was interrupted before the
    // editor joined the console. After that, let the editor cancel gracefully.
    DWORD probe;
    DWORD capacity = GetConsoleProcessList(&probe, 1);
    if (capacity <= 1) {
        return FALSE;
    }
    DWORD *processes = malloc(capacity * sizeof(*processes));
    if (processes == NULL) {
        return FALSE;
    }
    DWORD count = GetConsoleProcessList(processes, capacity);
    BOOL attached = FALSE;
    for (DWORD index = 0; count <= capacity && index < count; ++index) {
        if (processes[index] == process_id) {
            attached = TRUE;
            break;
        }
    }
    free(processes);
    return attached;
}

static int report_error(DWORD error) {
    fprintf(stderr, "adastudio: cannot run AdaEditor.exe (Windows error %lu).\n", (unsigned long)error);
    return 4;
}

static DWORD editor_path(wchar_t *path, DWORD capacity) {
    DWORD length = GetModuleFileNameW(NULL, path, capacity);
    if (length == 0 || length == capacity) {
        return GetLastError();
    }
    const wchar_t filename[] = L"AdaEditor.exe";
    DWORD attributes = GetFileAttributesW(path);
    if (attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
        HANDLE launcher = CreateFileW(path, 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING, 0, NULL);
        if (launcher == INVALID_HANDLE_VALUE) {
            return GetLastError();
        }
        length = GetFinalPathNameByHandleW(launcher, path, capacity, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
        DWORD error = length == 0 ? GetLastError() : ERROR_SUCCESS;
        CloseHandle(launcher);
        if (error != ERROR_SUCCESS || length >= capacity) {
            return error != ERROR_SUCCESS ? error : ERROR_INSUFFICIENT_BUFFER;
        }
        // The editor and SwiftPM resources use ordinary DOS/UNC paths when they fit.
        if (length + ARRAYSIZE(filename) < MAX_PATH) {
            if (wcsncmp(path, L"\\\\?\\UNC\\", 8) == 0) {
                memmove(path + 2, path + 8, (length - 7) * sizeof(*path));
                path[0] = path[1] = L'\\';
            } else if (wcsncmp(path, L"\\\\?\\", 4) == 0 && path[5] == L':') {
                memmove(path, path + 4, (length - 3) * sizeof(*path));
            }
        }
    }
    wchar_t *separator = wcsrchr(path, L'\\');
    if (separator == NULL || ARRAYSIZE(filename) > capacity - (size_t)(separator + 1 - path)) {
        return ERROR_BAD_PATHNAME;
    }
    memcpy(separator + 1, filename, sizeof(filename));
    return ERROR_SUCCESS;
}

static DWORD start_editor(const wchar_t *editor, wchar_t *command, STARTUPINFOEXW *startup, HANDLE job, PROCESS_INFORMATION *child) {
    SIZE_T bytes = 0;
    InitializeProcThreadAttributeList(NULL, 1, 0, &bytes);
    startup->lpAttributeList = malloc(bytes);
    if (startup->lpAttributeList == NULL) {
        return ERROR_NOT_ENOUGH_MEMORY;
    }
    DWORD error = ERROR_SUCCESS;
    if (InitializeProcThreadAttributeList(startup->lpAttributeList, 1, 0, &bytes)) {
        if (!UpdateProcThreadAttribute(startup->lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_JOB_LIST, &job, sizeof(job), NULL, NULL) ||
            !CreateProcessW(editor, command, NULL, NULL, TRUE, EXTENDED_STARTUPINFO_PRESENT, NULL, NULL, &startup->StartupInfo, child)) {
            error = GetLastError();
        }
        DeleteProcThreadAttributeList(startup->lpAttributeList);
    } else {
        error = GetLastError();
    }
    free(startup->lpAttributeList);
    return error;
}

int wmain(void) {
    wchar_t editor[32768];
    DWORD error = editor_path(editor, ARRAYSIZE(editor));
    if (error != ERROR_SUCCESS) {
        return report_error(error);
    }

    // Supply the image path separately so the original argv[0] selects CLI mode
    // and Windows can pass the original Unicode arguments without re-quoting.
    if (!SetConsoleCtrlHandler(handle_interrupt, TRUE)) {
        return report_error(GetLastError());
    }
    wchar_t *command = _wcsdup(GetCommandLineW());
    if (command == NULL) {
        return report_error(ERROR_NOT_ENOUGH_MEMORY);
    }
    HANDLE job = CreateJobObjectW(NULL, NULL);
    if (job == NULL) {
        error = GetLastError();
        free(command);
        return report_error(error);
    }
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = { 0 };
    // End the CLI if the caller kills the launcher. A project window started by
    // the CLI must be able to outlive the command that opened it.
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK;
    if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof(limits))) {
        error = GetLastError();
    }

    STARTUPINFOEXW startup = { .StartupInfo = { .cb = sizeof(startup), .dwFlags = STARTF_USESTDHANDLES } };
    const DWORD standard_handles[] = { STD_INPUT_HANDLE, STD_OUTPUT_HANDLE, STD_ERROR_HANDLE };
    HANDLE *child_handles[] = { &startup.StartupInfo.hStdInput, &startup.StartupInfo.hStdOutput, &startup.StartupInfo.hStdError };
    for (size_t index = 0; error == ERROR_SUCCESS && index < ARRAYSIZE(standard_handles); ++index) {
        HANDLE handle = GetStdHandle(standard_handles[index]);
        if (handle != NULL && handle != INVALID_HANDLE_VALUE &&
            !DuplicateHandle(GetCurrentProcess(), handle, GetCurrentProcess(), child_handles[index], 0, TRUE, DUPLICATE_SAME_ACCESS)) {
            error = GetLastError();
        }
    }

    PROCESS_INFORMATION child;
    if (error == ERROR_SUCCESS) {
        error = start_editor(editor, command, &startup, job, &child);
        if (error == ERROR_SUCCESS) {
            InterlockedExchange(&editor_process_id, (LONG)child.dwProcessId);
        }
    }
    free(command);
    for (size_t index = 0; index < ARRAYSIZE(child_handles); ++index) {
        if (*child_handles[index] != NULL) {
            CloseHandle(*child_handles[index]);
        }
    }
    if (error != ERROR_SUCCESS) {
        CloseHandle(job);
        return report_error(error);
    }

    CloseHandle(child.hThread);
    DWORD exit_code = 4;
    if (WaitForSingleObject(child.hProcess, INFINITE) != WAIT_OBJECT_0 || !GetExitCodeProcess(child.hProcess, &exit_code)) {
        error = GetLastError();
    }
    CloseHandle(child.hProcess);
    CloseHandle(job);
    return error == ERROR_SUCCESS ? (int)exit_code : report_error(error);
}
#else
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    (void)argc;
    char launcher[PATH_MAX];
    char editor[PATH_MAX];
    uint32_t length = sizeof(launcher);
    if (_NSGetExecutablePath(launcher, &length) != 0) {
        fputs("adastudio: launcher path is too long.\n", stderr);
        return 4;
    }
    if (realpath(launcher, editor) == NULL) {
        perror("adastudio: cannot resolve the launcher path");
        return 4;
    }
    char *filename = strrchr(editor, '/') + 1;
    size_t capacity = sizeof(editor) - (filename - editor);
    if (sizeof(ADA_STUDIO_EXECUTABLE) > capacity) {
        fputs("adastudio: editor path is too long.\n", stderr);
        return 4;
    }
    memcpy(filename, ADA_STUDIO_EXECUTABLE, sizeof(ADA_STUDIO_EXECUTABLE));

    // Preserve the CLI entry point and let exec preserve signals and exit status.
    argv[0] = "adastudio";
    execv(editor, argv);
    perror("adastudio: cannot run Ada Studio");
    return 4;
}
#endif
