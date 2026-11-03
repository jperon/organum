#!/bin/sh
# Usage : mkcharge.sh <dossier-moteur> <sortie>
# Compile tests/charge.cpp contre <dossier-moteur>/libaeolus.a avec la chaîne x86-64 seule
# (cosmoc++ échoue au lien aarch64 : on rejoue à la main les 3 commandes x86-64).
set -e
export TMPDIR=/tmp
M=$(cd "$1" && pwd); OUT=$2
cd "$M"
LOG=$(mktemp)
SRC=${3:-tests/charge.cpp}
BUILDLOG=$LOG ../externe/cosmocc/bin/cosmoc++ -O2 -std=c++17 -include compat/cosmo_linux.h -Icompat -I. -Iapi -Io/binarydata -I../externe/JUCE/modules -DJUCE_GLOBAL_MODULE_SETTINGS_INCLUDED=1 -DJUCE_STANDALONE_APPLICATION=1 -DJUCE_USE_CURL=0 -DJUCE_USE_FLAC=0 -DJUCE_USE_OGGVORBIS=0 -DJUCE_USE_MP3AUDIOFORMAT=0 -DJUCE_USE_LAME_AUDIO_FORMAT=0 -DJUCE_USE_WINDOWS_MEDIA_FORMAT=0 -DJUCE_MODULE_AVAILABLE_juce_core=1 -DJUCE_MODULE_AVAILABLE_juce_events=1 -DJUCE_MODULE_AVAILABLE_juce_data_structures=1 -DJUCE_MODULE_AVAILABLE_juce_audio_basics=1 -DJUCE_MODULE_AVAILABLE_juce_audio_formats=1 "$SRC" ../externe/JUCE/modules/juce_core/juce_core_CompilationTime.cpp -L. -laeolus -lpthread -ldl -lrt -lm -o /dev/null >/dev/null 2>&1 || true
grep "x86_64-linux-cosmo" "$LOG" | sed 's/^(cd [^;]*; //; s/)$//' > "$LOG.sh"
test "$(wc -l < "$LOG.sh")" -eq 3 || { echo "mkcharge: 3 commandes x86-64 attendues" >&2; exit 1; }
LINK=$(sed -n 3p "$LOG.sh")
sed -n 1p "$LOG.sh" | sh; sed -n 2p "$LOG.sh" | sh; echo "$LINK" | sh
F=$(echo "$LINK" | grep -o "/tmp/fatcosmocc\.[A-Za-z0-9]*\.com\.dbg" | head -1)
cp "$F" "$OUT"; chmod +x "$OUT"; echo "mkcharge: $OUT"
