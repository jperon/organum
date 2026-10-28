#pragma once
#include <sys/time.h>
struct timeb{time_t time;unsigned short millitm;short timezone,dstflag;};
