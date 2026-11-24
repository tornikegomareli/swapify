#pragma once

void spike_say(const char *text);
void spike_install_signal_handlers(void);
void spike_say_state(void);  // P_TRACED and CS_DEBUGGED
// dlopen, report the GOT, copy chain roots. Returns 0 on success.
int spike_load_patch(const char *path);
void spike_dataconst_probe(void);
