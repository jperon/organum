# Moteur d'Aeolus compilé avec cosmocc contre les modules JUCE sans interface
# graphique. Les chemins par défaut sont ceux de scripts/dependances.sh.
COSMO ?= ../externe/cosmocc
JUCE ?= ../externe/JUCE/modules
PYTHON ?= python3

# Architecture visée. Le x86-64 garde exactement les chemins historiques
# (o/ et libaeolus.a) ; l'aarch64 a ses propres objets et son archive pour
# qu'une construction croisée ne mélange jamais les deux jeux d'objets.
ARCH ?= x86_64
ifeq ($(ARCH),x86_64)
CXX := $(COSMO)/bin/cosmoc++
AR := $(COSMO)/bin/cosmoar
OBJDIR := o
LIB := libaeolus.a
else ifeq ($(ARCH),aarch64)
# aarch64-unknown-cosmo-c++ passe par cosmocross (le gcc aarch64-linux-cosmo
# échoue sur stdc-predef.h) ; l'AR de la même architecture convient.
CXX := $(COSMO)/bin/aarch64-unknown-cosmo-c++
AR := $(COSMO)/bin/aarch64-linux-cosmo-ar
OBJDIR := o-aarch64
LIB := libaeolus-aarch64.a
else
$(error ARCH doit valoir x86_64 ou aarch64, pas « $(ARCH) »)
endif

MODULES := juce_core juce_events juce_data_structures juce_audio_basics juce_audio_formats

CXXFLAGS ?= -O2
CXXFLAGS += -std=c++17 -include compat/cosmo_linux.h -Icompat -I. -Iapi -I$(OBJDIR)/binarydata -I$(JUCE) \
	-DJUCE_GLOBAL_MODULE_SETTINGS_INCLUDED=1 -DJUCE_STANDALONE_APPLICATION=1 \
	-DJUCE_USE_CURL=0 -DJUCE_USE_FLAC=0 -DJUCE_USE_OGGVORBIS=0 \
	-DJUCE_USE_MP3AUDIOFORMAT=0 -DJUCE_USE_LAME_AUDIO_FORMAT=0 \
	-DJUCE_USE_WINDOWS_MEDIA_FORMAT=0 \
	$(foreach m,$(MODULES),-DJUCE_MODULE_AVAILABLE_$(m)=1)

SRCS := $(wildcard compat/src/*.cpp aeolus/*.cpp aeolus/dsp/*.cpp mts/*.cpp api/*.cpp)
OBJS := $(SRCS:%.cpp=$(OBJDIR)/%.o) $(MODULES:%=$(OBJDIR)/juce/%.o) $(OBJDIR)/binarydata/BinaryData.o

all: $(LIB)

$(LIB): $(OBJS)
	rm -f $@
	$(AR) rcs $@ $^

# Jeux, réponses impulsionnelles et orgue par défaut, inclus dans le binaire.
RESSOURCES := $(shell sed -n 's/^[^\#][^\t]*\t//p' ressources.tsv)
$(OBJDIR)/binarydata/BinaryData.cpp: binarydata.py ressources.tsv $(RESSOURCES:%=ressources/%)
	$(PYTHON) binarydata.py ressources.tsv ressources $(OBJDIR)/binarydata
$(OBJDIR)/binarydata/BinaryData.h: $(OBJDIR)/binarydata/BinaryData.cpp
$(filter-out $(OBJDIR)/binarydata/%,$(OBJS)): | $(OBJDIR)/binarydata/BinaryData.h

$(OBJDIR)/binarydata/BinaryData.o: $(OBJDIR)/binarydata/BinaryData.cpp
	$(CXX) $(CXXFLAGS) -c $< -o $@

$(OBJDIR)/%.o: %.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) -c $< -o $@

# Chaque module JUCE se compile d'un seul fichier : $(JUCE)/<module>/<module>.cpp.
$(foreach m,$(MODULES),$(eval $(OBJDIR)/juce/$(m).o: $(JUCE)/$(m)/$(m).cpp))
$(OBJDIR)/juce/%.o:
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) -c $< -o $@

rendu: $(LIB) tests/rendu.cpp
	@mkdir -p tests
	$(CXX) $(CXXFLAGS) tests/rendu.cpp $(JUCE)/juce_core/juce_core_CompilationTime.cpp $(LIB) -lpthread -ldl -lrt -lm -o tests/rendu

# Mesure hors ligne de l'écrêtage d'un accord dense (hors build de production).
ecretage: $(LIB) tests/ecretage.cpp
	@mkdir -p tests
	$(CXX) $(CXXFLAGS) tests/ecretage.cpp $(JUCE)/juce_core/juce_core_CompilationTime.cpp $(LIB) -lpthread -ldl -lrt -lm -o tests/ecretage

# Polyphonie par accouplement : moteur complet, donc hors de la suite rapide.
# cosmoc++ échoue au lien aarch64 ; on rejoue les trois commandes x86-64.
polyphonie: $(LIB) tests/polyphonie.cpp
	sh tests/compiler-test-x86.sh . tests/polyphonie tests/polyphonie.cpp

clean:
	rm -rf o o-aarch64 libaeolus.a libaeolus-aarch64.a

.PHONY: all clean rendu ecretage polyphonie
