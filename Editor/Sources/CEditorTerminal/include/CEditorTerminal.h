#ifndef C_EDITOR_TERMINAL_H
#define C_EDITOR_TERMINAL_H
#include <stddef.h>
#include <stdint.h>
typedef struct AdaTerminal AdaTerminal;
// UTF-8 paths. The child starts in directory. Errors are copied to error.
AdaTerminal *ada_terminal_open(const char *directory, int columns, int rows, char *error, size_t capacity);
// Nonblocking read: 0 means no data yet, -1 means EOF/error.
int ada_terminal_read(AdaTerminal *terminal, uint8_t *bytes, int capacity);
int ada_terminal_write(AdaTerminal *terminal, const uint8_t *bytes, int count);
int ada_terminal_resize(AdaTerminal *terminal, int columns, int rows);
void ada_terminal_close(AdaTerminal *terminal);
#endif
