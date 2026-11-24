#pragma once

// Runs one test by name and returns the process exit code. Prints `SPIKE <test> ...` lines.
int spike_run(const char *name);
