// cosmopolitan déclare vswprintf sans la fournir ; JUCE ne s'en sert que
// dans String::formatted, que le moteur n'appelle pas.
#include <cwchar>
#include <cstdarg>
extern "C" int vswprintf(wchar_t *s, size_t n, const wchar_t *, va_list)
{
    if (s && n) s[0] = 0;
    return -1;
}
