#include <JuceHeader.h>
#include "aeolus_c.h"

#include <vector>
#include <cmath>
#include <cstdio>
#include <cstdlib>

int main(int argc, char** argv)
{
    if (argc < 2) {
        std::fprintf(stderr, "usage: %s <out.wav>\n", argv[0]);
        return 1;
    }

    const int sr = 44100;
    const int n1 = sr * 2;   // 2 s
    const int n2 = sr * 1;   // 1 s
    const int total = n1 + n2;

    void* moteur = aeolus_creer(sr);
    if (!moteur) {
        std::fprintf(stderr, "aeolus_creer failed\n");
        return 1;
    }

    // Activate first stop of first division.
    if (aeolus_nb_divisions(moteur) > 0 && aeolus_nb_jeux(moteur, 0) > 0) {
        aeolus_jeu(moteur, 0, 0, 1);
    }

    std::vector<float> L(total, 0.0f), R(total, 0.0f);

    // Note on 60, 64, 67 on channel 1.
    unsigned char on60[] = { 0x90, 60, 100 };
    unsigned char on64[] = { 0x90, 64, 100 };
    unsigned char on67[] = { 0x90, 67, 100 };
    aeolus_midi(moteur, on60, 3);
    aeolus_midi(moteur, on64, 3);
    aeolus_midi(moteur, on67, 3);

    aeolus_rendre(moteur, L.data(), R.data(), n1);

    // Note off.
    unsigned char off60[] = { 0x80, 60, 0 };
    unsigned char off64[] = { 0x80, 64, 0 };
    unsigned char off67[] = { 0x80, 67, 0 };
    aeolus_midi(moteur, off60, 3);
    aeolus_midi(moteur, off64, 3);
    aeolus_midi(moteur, off67, 3);

    aeolus_rendre(moteur, L.data() + n1, R.data() + n1, n2);

    // RMS.
    double sum = 0.0;
    for (int i = 0; i < total; ++i) {
        sum += (double)L[i] * L[i] + (double)R[i] * R[i];
    }
    double rms = std::sqrt(sum / (2.0 * total));
    std::printf("RMS = %.6f\n", rms);

    // Write WAV 16-bit stereo.
    juce::File outFile(argv[1]);
    outFile.deleteFile();
    std::unique_ptr<juce::OutputStream> stream(outFile.createOutputStream());
    if (!stream) {
        std::fprintf(stderr, "cannot create output stream\n");
        aeolus_detruire(moteur);
        return 1;
    }

    juce::WavAudioFormat wavFormat;
    std::unique_ptr<juce::AudioFormatWriter> writer(
        wavFormat.createWriterFor(stream.release(), sr, 2, 16, {}, 0));
    if (!writer) {
        std::fprintf(stderr, "cannot create wav writer\n");
        aeolus_detruire(moteur);
        return 1;
    }

    juce::AudioBuffer<float> buffer(2, total);
    for (int i = 0; i < total; ++i) {
        buffer.setSample(0, i, L[i]);
        buffer.setSample(1, i, R[i]);
    }
    writer->writeFromAudioSampleBuffer(buffer, 0, total);
    writer.reset();

    aeolus_detruire(moteur);
    return 0;
}