#-*-mode:makefile-gmake;indent-tabs-mode:t;tab-width:8;coding:utf-8-*-┐
#── vi: set noet ft=make ts=8 sw=8 fenc=utf-8 :vi ────────────────────┘
#
# ORGANUM : redbean + moteur d'Aeolus.
#
# tool/organum est un lien vers organum/cosmo (voir README.md). Le moteur,
# en C++ (JUCE), est construit à part par organum/moteur/Makefile avec la
# chaîne cosmocc issue de cet arbre, dont la libc++ est la même.

ORGANUM_MOTEUR ?= tool/organum/../moteur/libaeolus.a

# Commun aux deux exécutables : moteur et plateformes audio/MIDI.
TOOL_ORGANUM_COMMUN =							\
	o/$(MODE)/tool/organum/lorganum.o				\
	o/$(MODE)/tool/organum/plateforme_audio.o			\
	o/$(MODE)/tool/organum/plateforme_midi.o			\
	o/$(MODE)/tool/organum/plateforme_audio_win.o		\
	o/$(MODE)/tool/organum/plateforme_midi_win.o		\
	o/$(MODE)/tool/organum/plateforme_aiguillage.o

# organum : interfaces web et native ; organum-web : interface web seule.
TOOL_ORGANUM_OBJS =							\
	$(TOOL_ORGANUM_COMMUN)						\
	o/$(MODE)/tool/organum/organum.o				\
	o/$(MODE)/tool/organum/lnuklear.o
TOOL_ORGANUM_WEB_OBJS =							\
	$(TOOL_ORGANUM_COMMUN)						\
	o/$(MODE)/tool/organum/organum_web.o

# Notre code n'est pas tenu aux avertissements stricts de l'arbre.
$(TOOL_ORGANUM_OBJS) $(TOOL_ORGANUM_WEB_OBJS): private CFLAGS += -Wno-error

# L'édition des liens reçoit les prérequis en ordre inverse (uniqr) : les
# bibliothèques sont donc déclarées avant le code qui s'en sert.
# Dépendances communes aux deux exécutables, bibliothèques d'abord.
TOOL_ORGANUM_LIEN =							\
	$(TOOL_NET_DEPS)						\
	o/$(MODE)/libc/dlopen/dlopen.a					\
	o/$(MODE)/third_party/libcxx/libcxx.a				\
	$(ORGANUM_MOTEUR)						\
	$(TOOL_NET_REDBEAN_LUA_MODULES)					\
	o/$(MODE)/tool/net/.init.lua.zip.o				\
	o/$(MODE)/tool/net/favicon.ico.zip.o				\
	o/$(MODE)/tool/net/redbean.png.zip.o				\
	o/$(MODE)/tool/net/help.txt.zip.o

o/$(MODE)/tool/organum/organum.dbg:					\
		$(TOOL_ORGANUM_LIEN)					\
		$(TOOL_ORGANUM_OBJS)					\
		o/$(MODE)/tool/net/net.pkg				\
		$(CRT)							\
		$(APE_NO_MODIFY_SELF)
	@$(APELINK)

o/$(MODE)/tool/organum/organum-web.dbg:					\
		$(TOOL_ORGANUM_LIEN)					\
		$(TOOL_ORGANUM_WEB_OBJS)				\
		o/$(MODE)/tool/net/net.pkg				\
		$(CRT)							\
		$(APE_NO_MODIFY_SELF)
	@$(APELINK)

.PHONY: o/$(MODE)/tool/organum
o/$(MODE)/tool/organum:						\
		o/$(MODE)/tool/organum/organum				\
		o/$(MODE)/tool/organum/organum-web

# Test de la sortie audio avec la libc de l'arbre.
o/$(MODE)/tool/organum/bip.o: private CFLAGS += -Wno-error
o/$(MODE)/tool/organum/bip.dbg:						\
		$(TOOL_NET_DEPS)					\
		o/$(MODE)/libc/dlopen/dlopen.a				\
		o/$(MODE)/tool/organum/plateforme_audio.o		\
		o/$(MODE)/tool/organum/plateforme_audio_win.o		\
		o/$(MODE)/tool/organum/plateforme_aiguillage.o		\
		o/$(MODE)/tool/organum/plateforme_midi.o		\
		o/$(MODE)/tool/organum/plateforme_midi_win.o		\
		o/$(MODE)/tool/organum/bip.o				\
		$(CRT)							\
		$(APE_NO_MODIFY_SELF)
	@$(APELINK)

# Dépendances communes aux petits tests de la couche plate-forme.
TOOL_ORGANUM_TEST_DEPS =						\
		$(TOOL_NET_DEPS)					\
		o/$(MODE)/libc/dlopen/dlopen.a				\
		o/$(MODE)/tool/organum/plateforme_audio.o		\
		o/$(MODE)/tool/organum/plateforme_audio_win.o		\
		o/$(MODE)/tool/organum/plateforme_aiguillage.o		\
		o/$(MODE)/tool/organum/plateforme_midi.o		\
		o/$(MODE)/tool/organum/plateforme_midi_win.o

# Vérifie le message d'erreur quand libasound ne peut pas être chargée.
o/$(MODE)/tool/organum/erreur_alsa.o: private CFLAGS += -Wno-error
o/$(MODE)/tool/organum/erreur_alsa.dbg:					\
		$(TOOL_ORGANUM_TEST_DEPS)				\
		o/$(MODE)/tool/organum/erreur_alsa.o			\
		$(CRT)							\
		$(APE_NO_MODIFY_SELF)
	@$(APELINK)

# Vérifie la construction des chemins (répertoire libasound, hw:C,D).
o/$(MODE)/tool/organum/chemins_alsa.o: private CFLAGS += -Wno-error
o/$(MODE)/tool/organum/chemins_alsa.dbg:					\
		$(TOOL_ORGANUM_TEST_DEPS)				\
		o/$(MODE)/tool/organum/chemins_alsa.o			\
		$(CRT)							\
		$(APE_NO_MODIFY_SELF)
	@$(APELINK)

# Vérifie l'énumération des ports MIDI et les abonnements, sans séquenceur.
o/$(MODE)/tool/organum/ports_midi.o: private CFLAGS += -Wno-error
o/$(MODE)/tool/organum/ports_midi.dbg:					\
		$(TOOL_ORGANUM_TEST_DEPS)				\
		o/$(MODE)/tool/organum/ports_midi.o			\
		$(CRT)							\
		$(APE_NO_MODIFY_SELF)
	@$(APELINK)

# Vérifie les échecs open/fcntl du chemin ioctl, sans matériel.
o/$(MODE)/tool/organum/injection_alsa.o: private CFLAGS += -Wno-error
o/$(MODE)/tool/organum/injection_alsa.dbg:				\
		$(TOOL_ORGANUM_TEST_DEPS)				\
		o/$(MODE)/tool/organum/injection_alsa.o			\
		$(CRT)							\
		$(APE_NO_MODIFY_SELF)
	@$(APELINK)

# Vérifie la boucle d'écriture libasound et l'alignement PIPEWIRE_LATENCY.
o/$(MODE)/tool/organum/ecriture_alsa.o: private CFLAGS += -Wno-error
o/$(MODE)/tool/organum/ecriture_alsa.dbg:				\
		$(TOOL_ORGANUM_TEST_DEPS)				\
		o/$(MODE)/tool/organum/ecriture_alsa.o			\
		$(CRT)							\
		$(APE_NO_MODIFY_SELF)
	@$(APELINK)
