# PerVertexKHR expérimental : candidat c2 et qualification M4 (30 septembre 2026)

Suite de `PerVertexExperimental-CANDIDATE.md` (étape 1). Ce rapport ferme l'étape 2 (bundle), donne l'étape 3 sur M4,
renvoie l'étape 4 (coût) au rapport existant, et prépare l'étape 5 (revue d'Astra). **M1 et M2 restent à passer** : ils
demandent d'exécuter le bundle sur ces machines. Ce jalon n'est pas une extension publique conforme ; le périmètre reste
« à qualifier » jusqu'aux passages M1 et M2.

## 1. Identités

| Identité | Valeur |
|---|---|
| Sources | `b699b6f3b53d30cfce238105b0cdb255344e0d11` ; runtime identique à `fb3970cc` (vérifié par `package.sh`) |
| Bundle | `pervertex-experimental-c2` ; archive `2ff06e66efb2169337b33d3c78ddad76f012ce72be3f32efca6f00cd517d9533` ; `SHA256SUMS` `1f11dfa897720217e353e23f0319479e8105bb9c80d7744c4b7e7d193d2ae05c` |
| Bibliothèque | `87e91213b1a6976efa584f45be12559b86ea130c534872ad8b0e76e796dbedbd` ; révision embarquée `b699b6f3` |
| `deqp-vk` | `32ba299fc9b91e42717148940f10b79283d84bba6d7d2c3fe4f3292eea04b518` |
| SPIRV-Cross | `6af5a67f` |

## 2. Configuration et choix de l'étape 2

- Configuration fixée par Astra : Debug arm64, admission TES OFF, adaptateur lié, `MVK_USE_METAL_PRIVATE_API` OFF
  (vérifié dans `CMakeCache.txt`), CTS incluse, aucun test ajouté.
- **Cible macOS 11.0** pour la bibliothèque, les programmes et `deqp-vk`, comme le bundle r14 : la version de macOS des M1
  et M2 n'est pas connue, et la bibliothèque et le `deqp-vk` par défaut exigeaient macOS 27.
- **`deqp-vk` recompilé** depuis le même commit CTS (`f6a29701`), en Release arm64, avec la libpng de la CTS : le binaire
  de référence dépendait de la libpng de Homebrew. Les données CTS produites sont identiques à celles du build de
  référence (`diff -r` vide).
- Le shim CTS est inchangé par rapport aux courses de référence : il ouvre aussi l'adaptateur mesh, sans effet sur les
  listes D, E et F, qui ne contiennent aucun cas mesh. L'activation du candidat pour une application reste
  `mvkEnableTESFixtureDevice` seul ; la sonde du bundle n'ouvre que lui.

## 3. Les cinq points d'Astra pour l'étape 2

1. **Trois identités distinctes** (section 1), et la bibliothèque réellement chargée vérifiée à l'exécution : dyld
   (`DYLD_PRINT_LIBRARIES`) ne doit nommer que la bibliothèque du bundle, dont l'empreinte est recalculée sur le chemin
   rapporté, et la révision publiée par `pipelineCacheUUID` doit valoir le SHA court des sources.
2. **Listes et entrées embarquées** : `lists/` (D, E), `inputs/` (`barycentric-runnable.txt`, `barycentric.txt`,
   `SOURCE.txt`, les empreintes de `build/cts-lists`, les résultats de référence de E), `cts/vulkan/`, `shaders/`, et
   toutes leurs empreintes dans `SHA256SUMS`.
3. **Autonome** : programmes, shim et `deqp-vk` précompilés ; `run.sh`, `cts.pl`, `compare.pl` et `timeout.pl` n'emploient
   que Bash, Perl et les outils de macOS. Ni Xcode, ni Homebrew, ni Python, ni réseau.
4. **Bornes et arrêt** : 60 s par cas B et C ; paquets CTS de 200 cas, 1 800 s par paquet ; plancher disque de 8 Gio.
   Chaque étape compare **chaque cas, par nom et statut**, à `expected/` ; la première divergence arrête les étapes
   suivantes. Chaque journal doit annoncer la validation Metal, ne contenir aucune erreur, et ne charger que la
   bibliothèque du bundle.
5. **F nommé « bibliothèque candidate sans activation »** : l'adaptateur reste lié mais n'est jamais appelé. Le README
   précise que ce n'est pas un build de production sans adaptateur, que le bundle ne contient ni ne teste.

## 4. Qualification M4 (étape 3)

Apple M4 Pro, macOS 27.2 (26B5091g). Le bundle a été extrait de son archive, comme sur un autre Mac.

| Réf. | Test | Résultat M4 |
|---|---|---|
| G | Identité et garde à l'API | PASS : révision `b699b6f3`, bibliothèque chargée = celle du bundle (`87e91213…`) ; `fragmentShaderBarycentric` 0 sans activation, 1 après |
| A | 8 suites hôte, même commit source | 8/8 PASS (`prefill`, `helper-preflight`, `scratch`, `draw-size`, `restart` : 74 136 motifs, `topology`, `capture-variant`, `memoryless`) |
| B | Oracle de topologie dynamique, 14 cas | identique : 14 PASS, dont les modes `weights*` pour la première fois depuis `fb3970cc` |
| C | Séparation capture/rejeu, memoryless | identique : 2 REFUSED (sortie 4) |
| D | CTS périmètre minimal, 1 201 cas | identique : 1 201 Pass |
| E | CTS ordinaire, 562 cas | identique cas par cas : 258 Pass, 299 NotSupported, 5 Fail (`VK_ERROR_FEATURE_NOT_PRESENT`, `*_bind_unused_ms`) |
| F | Bibliothèque candidate sans activation, 1 201 cas | identique : 1 201 NotSupported |

Chaque paquet CTS (7 pour D, 3 pour E, 7 pour F) a chargé une seule image MoltenVK, la bonne, annoncé la validation
Metal et ne contient aucune erreur de validation ; aucun plantage. Les attendus ON/ON de D et E sont désormais
**mesurés** dans la configuration OFF/ON sur M4 ; la prévision de F est vérifiée sur M4.

## 5. Incident : le bundle c1

Le premier bundle (`c1`, sources `fde45c41`) a échoué à sa vérification d'identité dès `--verify-only` : sur macOS 27,
dyld écrit chaque image sous la forme `<UUID> chemin`, que `run.sh` ne lisait pas. La bibliothèque chargée était pourtant
la bonne. Aucune étape GPU n'a tourné depuis c1. Correctif `b699b6f3`, bundle `c2` ; c1 est conservé avec une note.

## 6. M1 et M2 (reste de l'étape 3)

Sur chaque Mac, avec l'archive `pervertex-experimental-c2.tar.gz` et son `.sha256` :

```bash
shasum -a 256 -c pervertex-experimental-c2.tar.gz.sha256
tar -xzf pervertex-experimental-c2.tar.gz
cd pervertex-experimental-c2
./run.sh --verify-only
./run.sh --qualify
```

Renvoyer toutes les archives `reports/*.tar.gz`. Critère : les mêmes identités et la même garde qu'en G, et B à F
identiques à leurs attendus, cas par cas. Toute divergence sur M1 ou M2 est une donnée à analyser avant correctif.
Seuls les blocages démontrés du périmètre seront corrigés, ce qui produirait un bundle c3 avec un nouveau passage M4.

## 7. Coût (étape 4)

`PerVertexCost-REPORT.md` fait foi : coût CPU mesuré, **coût GPU non qualifié**. Il a été mesuré sur une bibliothèque
Release avec admission, pas sur le candidat Debug ; aucune nouvelle mesure ni optimisation.

## 8. Ce que le candidat permet, et ses limites

- **Qualifié sur M4, à confirmer sur M1 et M2** : le périmètre de `PerVertexExperimental-CANDIDATE.md` (section 4).
- **Admis sans preuve GPU dans la liste** : plusieurs instances, `vertexOffset` non nul, redémarrage de primitive, index
  uint8 et uint16, command buffers secondaires et préremplissage, `viewMask` d'une seule vue. Non qualifiés.
- **Hors périmètre** : indirect, TES, mesh, natif Apple10, MSAA, multiview, sommet provoquant dernier, `polygonMode`
  autre que `FILL`, API privée ON, adjacence. Aucun poids promis pour les points et les lignes.
- **Limite expérimentale** : les attachements memoryless importés sont refusés à travers la séparation capture/rejeu
  (C) ; ce refus n'est pas démontré légal au sens de Vulkan.
- **Gardes publiques fermées** : sans `mvkEnableTESFixtureDevice`, l'extension est absente (G, F). La bibliothèque
  contient les crochets de test : elle n'est pas une bibliothèque de distribution.

## 9. Défauts annexes consignés

1. Le CMake de MoltenVK grave dans `mvkRevString` la révision git du dossier courant (`execute_process` sans
   `WORKING_DIRECTORY`) : un build configuré ailleurs porte une révision fausse. Correctif upstream possible, hors
   de ce jalon.
2. Le runner CTS du fork (`run-pervertex-cts.sh`) dépend de Python et de `gtimeout` ; le bundle les remplace
   (`cts.pl`), le runner de développement reste tel quel.
3. Le clone principal `SPIRV-Cross` porte des modifications non commitées du 27 septembre ; non touché.

## 10. Preuves

- `build/astra/experimental-c2/` : archive et `.sha256`, bundle construit, journaux de construction de la bibliothèque,
  rapports M4 (`m4/pervertex-experimental-c2/reports/*.tar.gz`), suites hôte (`host-A/`), `EVIDENCE.sha256` (20
  fichiers, `2fce43f7…`).
- `build/astra/experimental-c1/` : c1, son rapport d'échec et `NOTE.txt`, `EVIDENCE.sha256` (4 fichiers).
- Outillage : `MoltenVK/Tests/PerVertexExperimentalBundle/` (`package.sh`, `run.sh`, `cts.pl`, `compare.pl`, `README.md`).
