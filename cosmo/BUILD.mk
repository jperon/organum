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
o/$(MODE)/tool/organum/organum.dbg:					\
		$(TOOL_NET_DEPS)					\
		o/$(MODE)/libc/dlopen/dlopen.a				\
		o/$(MODE)/third_party/libcxx/libcxx.a			\
		$(ORGANUM_MOTEUR)					\
		$(TOOL_NET_REDBEAN_LUA_MODULES)				\
		o/$(MODE)/tool/net/.init.lua.zip.o			\
		o/$(MODE)/tool/net/favicon.ico.zip.o			\
		o/$(MODE)/tool/net/redbean.png.zip.o			\
		o/$(MODE)/tool/net/help.txt.zip.o			\
		$(TOOL_ORGANUM_OBJS)					\
		o/$(MODE)/tool/net/net.pkg				\
		$(CRT)							\
		$(APE_NO_MODIFY_SELF)
	@$(APELINK)

o/$(MODE)/tool/organum/organum-web.dbg:					\
		$(TOOL_NET_DEPS)					\
		o/$(MODE)/libc/dlopen/dlopen.a				\
		o/$(MODE)/third_party/libcxx/libcxx.a			\
		$(ORGANUM_MOTEUR)					\
		$(TOOL_NET_REDBEAN_LUA_MODULES)				\
		o/$(MODE)/tool/net/.init.lua.zip.o			\
		o/$(MODE)/tool/net/favicon.ico.zip.o			\
		o/$(MODE)/tool/net/redbean.png.zip.o			\
		o/$(MODE)/tool/net/help.txt.zip.o			\
		$(TOOL_ORGANUM_WEB_OBJS)					\
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
