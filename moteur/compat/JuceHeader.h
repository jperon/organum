// Remplace l'en-tête généré par Projucer : seuls les modules sans interface
// graphique dont dépend le moteur.
#pragma once
#include <juce_core/juce_core.h>
#include <juce_events/juce_events.h>
#include <juce_data_structures/juce_data_structures.h>
#include <juce_audio_basics/juce_audio_basics.h>
#include <juce_audio_formats/juce_audio_formats.h>
#include "BinaryData.h"
using namespace juce;

// Constantes générées par la construction CMake du greffon.
namespace ProjectInfo
{
    const char* const  projectName    = "Aeolus";
    const char* const  companyName    = "Arthur Benilov";
    const char* const  versionString  = "0.3.0";
    const int          versionNumber  =  0x300;
}

namespace juce {
// Le moteur n'utilise de juce_audio_processors que ce paramètre (gain des
// divisions) et un pointeur opaque sur le processeur hôte.
class AudioProcessor;

class AudioParameterFloat
{
public:
    AudioParameterFloat(float v = 0.0f) : _value(v) {}
    float get() const noexcept { return _value.load(); }
    operator float() const noexcept { return get(); }
    AudioParameterFloat& operator=(float v) { _value.store(v); return *this; }
    void setValueNotifyingHost(float v) { _value.store(v); }
private:
    std::atomic<float> _value;
};
}
