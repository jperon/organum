#include "aeolus_c.h"

#include <JuceHeader.h>
#include "aeolus/engine.h"
#include "aeolus/division.h"

#include <cstring>
#include <cstdlib>
#include <cstdarg>
#include <cwchar>
using namespace juce;
AEOLUS_USING_NAMESPACE

namespace
{
    class MidiListener : public juce::MidiKeyboardState::Listener
    {
    public:
        explicit MidiListener(aeolus::Engine& e) : _engine(e) {}

        void handleNoteOn(juce::MidiKeyboardState*, int midiChannel, int midiNoteNumber, float) override
        {
            _engine.noteOn(midiNoteNumber, midiChannel);
        }

        void handleNoteOff(juce::MidiKeyboardState*, int midiChannel, int midiNoteNumber, float) override
        {
            _engine.noteOff(midiNoteNumber, midiChannel);
        }

    private:
        aeolus::Engine& _engine;
    };

    struct Handle
    {
        aeolus::Engine* engine;
        MidiListener* listener;
    };
}

extern "C" void* aeolus_creer(int taux)
{
    auto* h = new Handle();
    h->engine = new aeolus::Engine();
    h->listener = new MidiListener(*h->engine);

    // Match the plugin: register a listener so that MIDI note events routed
    // through MidiKeyboardState actually trigger voices.
    h->engine->getMidiKeyboardState().addListener(h->listener);

    // Prepare the engine (loads stops, IR, etc.).
    h->engine->prepareToPlay((float)taux, 512);

    // Provide a gain parameter for each division (the plugin does this via
    // Parameters). Without it Division::modulate() would dereference null.
    for (int i = 0; i < h->engine->getDivisionCount(); ++i) {
        auto* div = h->engine->getDivisionByIndex(i);
        auto* param = new juce::AudioParameterFloat(0.5f);
        div->setParamGain(param);
    }

    // Reasonable defaults matching the plugin.
    h->engine->setVolume(0.5f);
    h->engine->setReverbWet(0.25f);

    return (void*)h;
}

extern "C" void aeolus_detruire(void* moteur)
{
    if (!moteur) return;
    auto* h = static_cast<Handle*>(moteur);
    if (h->engine) {
        h->engine->getMidiKeyboardState().removeListener(h->listener);
        delete h->engine;
    }
    delete h->listener;
    delete h;
}

extern "C" int aeolus_nb_divisions(void* moteur)
{
    if (!moteur) return 0;
    return static_cast<Handle*>(moteur)->engine->getDivisionCount();
}

extern "C" const char* aeolus_nom_division(void* moteur, int div)
{
    if (!moteur) return nullptr;
    auto* e = static_cast<Handle*>(moteur)->engine;
    if (div < 0 || div >= e->getDivisionCount()) return nullptr;
    juce::String s = e->getDivisionByIndex(div)->getName();
    char* buf = (char*)std::malloc(s.length() + 1);
    std::strcpy(buf, s.toRawUTF8());
    return buf;
}

extern "C" int aeolus_nb_jeux(void* moteur, int div)
{
    if (!moteur) return 0;
    auto* e = static_cast<Handle*>(moteur)->engine;
    if (div < 0 || div >= e->getDivisionCount()) return 0;
    return e->getDivisionByIndex(div)->getStopsCount();
}

extern "C" const char* aeolus_nom_jeu(void* moteur, int div, int j)
{
    if (!moteur) return nullptr;
    auto* e = static_cast<Handle*>(moteur)->engine;
    if (div < 0 || div >= e->getDivisionCount()) return nullptr;
    auto* d = e->getDivisionByIndex(div);
    if (j < 0 || j >= d->getStopsCount()) return nullptr;
    juce::String s = d->getStopByIndex(j).getName();
    char* buf = (char*)std::malloc(s.length() + 1);
    std::strcpy(buf, s.toRawUTF8());
    return buf;
}

extern "C" void aeolus_jeu(void* moteur, int div, int j, int actif)
{
    if (!moteur) return;
    auto* e = static_cast<Handle*>(moteur)->engine;
    if (div < 0 || div >= e->getDivisionCount()) return;
    auto* d = e->getDivisionByIndex(div);
    if (j < 0 || j >= d->getStopsCount()) return;
    d->enableStop(j, actif != 0);
}

extern "C" void aeolus_midi(void* moteur, const unsigned char* octets, int n)
{
    if (!moteur || !octets || n <= 0) return;
    auto* e = static_cast<Handle*>(moteur)->engine;

    juce::MidiMessage msg(octets, n);
    e->processMIDIMessage(msg);
}

extern "C" void aeolus_volume(void* moteur, float v)
{
    if (!moteur) return;
    static_cast<Handle*>(moteur)->engine->setVolume(v);
}

extern "C" void aeolus_reverb(void* moteur, float v)
{
    if (!moteur) return;
    static_cast<Handle*>(moteur)->engine->setReverbWet(v);
}

extern "C" void aeolus_gain(void* moteur, int div, float v)
{
    if (!moteur) return;
    auto* e = static_cast<Handle*>(moteur)->engine;
    if (div < 0 || div >= e->getDivisionCount()) return;
    auto* d = e->getDivisionByIndex(div);
    if (d->getParamGain())
        *d->getParamGain() = v;
}

extern "C" void aeolus_rendre(void* moteur, float* g, float* d, int n)
{
    if (!moteur || !g || !d || n <= 0) return;
    static_cast<Handle*>(moteur)->engine->process(g, d, n, true);
}
extern "C" int aeolus_jeu_actif(void* moteur, int div, int j)
{
    if (!moteur) return 0;
    auto* e = static_cast<Handle*>(moteur)->engine;
    if (div < 0 || div >= e->getDivisionCount()) return 0;
    auto* d = e->getDivisionByIndex(div);
    if (j < 0 || j >= d->getStopsCount()) return 0;
    return d->isStopEnabled(j) ? 1 : 0;
}

extern "C" float aeolus_lire_gain(void* moteur, int div)
{
    if (!moteur) return 0.0f;
    auto* e = static_cast<Handle*>(moteur)->engine;
    if (div < 0 || div >= e->getDivisionCount()) return 0.0f;
    auto* p = e->getDivisionByIndex(div)->getParamGain();
    return p ? p->get() : 0.0f;
}

extern "C" float aeolus_lire_volume(void* moteur)
{
    return moteur ? static_cast<Handle*>(moteur)->engine->getVolume() : 0.0f;
}

extern "C" float aeolus_lire_reverb(void* moteur)
{
    return moteur ? static_cast<Handle*>(moteur)->engine->getReverbWet() : 0.0f;
}

extern "C" int aeolus_canaux_division(void* moteur, int div)
{
    if (!moteur) return 0;
    auto* e = static_cast<Handle*>(moteur)->engine;
    if (div < 0 || div >= e->getDivisionCount()) return 0;
    return e->getDivisionByIndex(div)->getMIDIChannelsMask();
}

extern "C" void aeolus_fixer_canaux_division(void* moteur, int div, int masque)
{
    if (!moteur) return;
    auto* e = static_cast<Handle*>(moteur)->engine;
    if (div < 0 || div >= e->getDivisionCount()) return;
    e->getDivisionByIndex(div)->setMIDIChannelsMask(masque & 0xFFFF);
}

extern "C" int aeolus_canaux_controle(void* moteur)
{
    return moteur ? static_cast<Handle*>(moteur)->engine->getMIDIControlChannelsMask() : 0;
}

extern "C" void aeolus_fixer_canaux_controle(void* moteur, int masque)
{
    if (moteur) static_cast<Handle*>(moteur)->engine->setMIDIControlChannelsMask(masque & 0xFFFF);
}

extern "C" int aeolus_canaux_expression(void* moteur)
{
    return moteur ? static_cast<Handle*>(moteur)->engine->getMIDISwellChannelsMask() : 0;
}

extern "C" void aeolus_fixer_canaux_expression(void* moteur, int masque)
{
    if (moteur) static_cast<Handle*>(moteur)->engine->setMIDISwellChannelsMask(masque & 0xFFFF);
}

namespace
{
    aeolus::Division* division(void* moteur, int div)
    {
        if (!moteur) return nullptr;
        auto* e = static_cast<Handle*>(moteur)->engine;
        return div >= 0 && div < e->getDivisionCount() ? e->getDivisionByIndex(div) : nullptr;
    }
}

extern "C" int aeolus_nb_liens(void* moteur, int div)
{
    auto* d = division(moteur, div);
    return d ? d->getLinksCount() : 0;
}

extern "C" int aeolus_division_liee(void* moteur, int div, int lien)
{
    auto* d = division(moteur, div);
    if (!d || lien < 0 || lien >= d->getLinksCount()) return -1;
    auto* cible = d->getLinkByIndex(lien).division;
    auto* e = static_cast<Handle*>(moteur)->engine;
    for (int i = 0; i < e->getDivisionCount(); ++i)
        if (e->getDivisionByIndex(i) == cible) return i;
    return -1;
}

extern "C" int aeolus_lien_actif(void* moteur, int div, int lien)
{
    auto* d = division(moteur, div);
    return d && lien >= 0 && lien < d->getLinksCount() && d->isLinkEnabled(lien) ? 1 : 0;
}

extern "C" void aeolus_lien(void* moteur, int div, int lien, int actif)
{
    auto* d = division(moteur, div);
    if (d && lien >= 0 && lien < d->getLinksCount()) d->enableLink(lien, actif != 0);
}

extern "C" int aeolus_etape(void* moteur)
{
    return moteur ? static_cast<Handle*>(moteur)->engine->getSequencer()->getCurrentStep() : 0;
}

extern "C" int aeolus_nb_etapes(void* moteur)
{
    return moteur ? static_cast<Handle*>(moteur)->engine->getSequencer()->getStepsCount() : 0;
}

extern "C" char* aeolus_sauvegarder(void* moteur)
{
    if (!moteur) return nullptr;
    auto json = juce::JSON::toString(static_cast<Handle*>(moteur)->engine->getPersistentState(), true);
    return strdup(json.toRawUTF8());
}

extern "C" int aeolus_restaurer(void* moteur, const char* json)
{
    if (!moteur || !json) return -1;
    juce::var etat;
    if (juce::JSON::parse(juce::String::fromUTF8(json), etat).failed()) return -1;
    static_cast<Handle*>(moteur)->engine->setPersistentState(etat);
    return 0;
}

extern "C" void aeolus_capturer_etape(void* moteur)
{
    if (moteur) static_cast<Handle*>(moteur)->engine->getSequencer()->captureCurrentStep();
}
