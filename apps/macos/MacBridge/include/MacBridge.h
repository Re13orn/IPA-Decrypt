#include <stdint.h>
char *IPAToolCall(char *request);
void IPAToolFree(char *allocation);
void IPAToolTransferProgress(int64_t *received, int64_t *total);
void IPALabResetTestFlightProgress(void);
int IPALabTestFlightProgress(int64_t *received, int64_t *total);
