#!/usr/bin/env python3
"""Génère BinaryData.h et BinaryData.cpp (format JUCE) à partir de
ressources.tsv : jeux, réponses impulsionnelles et orgue par défaut sont
ainsi compilés dans l'exécutable.

Les noms des ressources sont ceux que produisait le BinaryData du greffon
Aeolus : le moteur en dérive les noms de jeux, référencés par
configs/default_organ.json. Les données sont incluses par .incbin, ce qui
évite de compiler des dizaines de mégaoctets de littéraux.

Usage : binarydata.py ressources.tsv dossier_ressources dossier_sortie
"""
import os
import sys

manifeste, racine, sortie = sys.argv[1:4]
racine = os.path.abspath(racine)
entrees = []
for ligne in open(manifeste, encoding="utf-8"):
    if ligne.strip() and not ligne.startswith("#"):
        nom, chemin = ligne.rstrip("\n").split("\t")
        entrees.append((nom, chemin, os.path.getsize(os.path.join(racine, chemin))))

os.makedirs(sortie, exist_ok=True)

with open(os.path.join(sortie, "BinaryData.h"), "w") as h:
    h.write("// Fichier généré par binarydata.py : ne pas modifier.\n#pragma once\n\n")
    h.write("namespace BinaryData\n{\n")
    for nom, _, taille in entrees:
        h.write(f"    extern const char* {nom};\n    const int {nom}Size = {taille};\n")
    h.write(f"\n    const int namedResourceListSize = {len(entrees)};\n")
    h.write("    extern const char* namedResourceList[];\n")
    h.write("    extern const char* originalFilenames[];\n")
    h.write("    const char* getNamedResource (const char* resourceNameUTF8, int& dataSizeInBytes);\n")
    h.write("    const char* getNamedResourceOriginalFilename (const char* resourceNameUTF8);\n")
    h.write("}\n")

with open(os.path.join(sortie, "BinaryData.cpp"), "w") as c:
    c.write("// Fichier généré par binarydata.py : ne pas modifier.\n")
    c.write('#include <cstring>\n#include "BinaryData.h"\n\n')
    for i, (nom, chemin, _) in enumerate(entrees):
        fichier = os.path.join(racine, chemin).replace("\\", "/")
        c.write(f'asm(".section .rodata\\n.balign 16\\n'
                f'organum_ressource_{i}: .incbin \\"{fichier}\\"\\n.byte 0\\n.previous");\n')
    c.write('\nextern "C" const char ' +
            ", ".join(f'organum_ressource_{i}[] asm("organum_ressource_{i}")'
                      for i in range(len(entrees))) + ";\n\n")
    c.write("namespace BinaryData\n{\n")
    for i, (nom, _, _) in enumerate(entrees):
        c.write(f"const char* {nom} = organum_ressource_{i};\n")
    c.write("\nconst char* namedResourceList[] =\n{\n")
    c.writelines(f'    "{nom}",\n' for nom, _, _ in entrees)
    c.write("};\n\nconst char* originalFilenames[] =\n{\n")
    c.writelines(f'    "{os.path.basename(chemin)}",\n' for _, chemin, _ in entrees)
    c.write("};\n\n")
    c.write("const char* getNamedResource (const char* nom, int& taille)\n{\n")
    for nom, _, t in entrees:
        c.write(f'    if (std::strcmp (nom, "{nom}") == 0) {{ taille = {t}; return {nom}; }}\n')
    c.write("    taille = 0;\n    return nullptr;\n}\n\n")
    c.write("const char* getNamedResourceOriginalFilename (const char* nom)\n{\n")
    c.write("    for (int i = 0; i < namedResourceListSize; ++i)\n")
    c.write("        if (std::strcmp (namedResourceList[i], nom) == 0)\n")
    c.write("            return originalFilenames[i];\n    return nullptr;\n}\n}\n")
