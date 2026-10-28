# Moteur d'Aeolus compilé avec cosmocc contre les modules JUCE sans interface
# graphique. Les chemins par défaut sont ceux de scripts/dependances.sh.
COSMO ?= ../externe/cosmocc
CXX := $(COSMO)/bin/cosmoc++
AR := $(COSMO)/bin/cosmoar
JUCE ?= ../externe/JUCE/modules
PYTHON ?= python3

MODULES := juce_core juce_events juce_data_structures juce_audio_basics juce_audio_formats

CXXFLAGS ?= -O2
CXXFLAGS += -std=c++17 -include compat/cosmo_linux.h -Icompat -I. -Iapi -Io/binarydata -I$(JUCE) \
	-DJUCE_GLOBAL_MODULE_SETTINGS_INCLUDED=1 -DJUCE_STANDALONE_APPLICATION=1 \
	-DJUCE_USE_CURL=0 -DJUCE_USE_FLAC=0 -DJUCE_USE_OGGVORBIS=0 \
	-DJUCE_USE_MP3AUDIOFORMAT=0 -DJUCE_USE_LAME_AUDIO_FORMAT=0 \
	-DJUCE_USE_WINDOWS_MEDIA_FORMAT=0 \
	$(foreach m,$(MODULES),-DJUCE_MODULE_AVAILABLE_$(m)=1)

SRCS := $(wildcard compat/src/*.cpp aeolus/*.cpp aeolus/dsp/*.cpp mts/*.cpp api/*.cpp)
OBJS := $(SRCS:%.cpp=o/%.o) $(MODULES:%=o/juce/%.o) o/binarydata/BinaryData.o

all: libaeolus.a

libaeolus.a: $(OBJS)
	rm -f $@
	$(AR) rcs $@ $^

# Jeux, réponses impulsionnelles et orgue par défaut, inclus dans le binaire.
RESSOURCES := $(shell sed -n 's/^[^\#][^\t]*\t//p' ressources.tsv)
o/binarydata/BinaryData.cpp: binarydata.py ressources.tsv $(RESSOURCES:%=ressources/%)
	$(PYTHON) binarydata.py ressources.tsv ressources o/binarydata
o/binarydata/BinaryData.h: o/binarydata/BinaryData.cpp
$(filter-out o/binarydata/%,$(OBJS)): | o/binarydata/BinaryData.h

o/binarydata/BinaryData.o: o/binarydata/BinaryData.cpp
	$(CXX) $(CXXFLAGS) -c $< -o $@

o/%.o: %.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) -c $< -o $@

# Chaque module JUCE se compile d'un seul fichier : $(JUCE)/<module>/<module>.cpp.
$(foreach m,$(MODULES),$(eval o/juce/$(m).o: $(JUCE)/$(m)/$(m).cpp))
o/juce/%.o:
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) -c $< -o $@

rendu: libaeolus.a tests/rendu.cpp
	@mkdir -p tests
	$(CXX) $(CXXFLAGS) tests/rendu.cpp $(JUCE)/juce_core/juce_core_CompilationTime.cpp -L. -laeolus -lpthread -ldl -lrt -lm -o tests/rendu

clean:
	rm -rf o libaeolus.a

.PHONY: all clean
