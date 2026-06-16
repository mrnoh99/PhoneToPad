#import "MacNowPlayingRunner.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char *shell_quote(const char *value) {
    size_t len = strlen(value);
    size_t cap = len * 4 + 3;
    char *out = malloc(cap);
    if (!out) { return NULL; }
    size_t pos = 0;
    out[pos++] = '\'';
    for (size_t i = 0; i < len; i++) {
        if (value[i] == '\'') {
            if (pos + 4 >= cap) { free(out); return NULL; }
            out[pos++] = '\'';
            out[pos++] = '\\';
            out[pos++] = '\'';
            out[pos++] = '\'';
        } else {
            if (pos + 1 >= cap) { free(out); return NULL; }
            out[pos++] = value[i];
        }
    }
    out[pos++] = '\'';
    out[pos] = '\0';
    return out;
}

char *PhoneToPadRunOsascript(char *const *arguments, int argumentCount) {
    if (argumentCount < 1 || arguments == NULL) { return NULL; }

    size_t cmdCap = 256;
    char *cmd = malloc(cmdCap);
    if (!cmd) { return NULL; }
    cmd[0] = '\0';

    for (int i = 0; i < argumentCount; i++) {
        char *quoted = shell_quote(arguments[i]);
        if (!quoted) { free(cmd); return NULL; }

        size_t need = strlen(cmd) + strlen(quoted) + 2;
        if (need >= cmdCap) {
            cmdCap = need + 64;
            char *grown = realloc(cmd, cmdCap);
            if (!grown) { free(quoted); free(cmd); return NULL; }
            cmd = grown;
        }
        if (cmd[0] != '\0') { strcat(cmd, " "); }
        strcat(cmd, quoted);
        free(quoted);
    }

    FILE *pipe = popen(cmd, "r");
    free(cmd);
    if (!pipe) { return NULL; }

    size_t outCap = 4096;
    size_t outLen = 0;
    char *output = malloc(outCap);
    if (!output) { pclose(pipe); return NULL; }
    output[0] = '\0';

    char buffer[4096];
    while (fgets(buffer, sizeof(buffer), pipe) != NULL) {
        size_t chunk = strlen(buffer);
        if (outLen + chunk + 1 >= outCap) {
            outCap = outLen + chunk + 4096;
            char *grown = realloc(output, outCap);
            if (!grown) { free(output); pclose(pipe); return NULL; }
            output = grown;
        }
        memcpy(output + outLen, buffer, chunk);
        outLen += chunk;
        output[outLen] = '\0';
    }

    pclose(pipe);

    while (outLen > 0 && (output[outLen - 1] == '\n' || output[outLen - 1] == '\r' || output[outLen - 1] == ' ' || output[outLen - 1] == '\t')) {
        output[--outLen] = '\0';
    }

    return output;
}
