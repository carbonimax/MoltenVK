# PerVertexKHR portable : coût face à un dessin ordinaire sur M4 (30 septembre 2026)

Premier passage du chantier de mesure demandé par Astra. Aucune optimisation, aucune nouvelle admission. **La charge de fond n'était pas contrôlée** (section 4) : les mesures GPU de ce passage sont exploratoires. Les mesures CPU, mémoire et par encodeur sont nettes.

## 1. Ce qui est mesuré, et sur quoi

**Machine et outils.** Apple M4 Pro, macOS 27.2 (26B5091g), Xcode 27.1 (27A9269).

**Code mesuré.**
- MoltenVK : runtime de `fb3970cc`, sans changement depuis.
- SPIRV-Cross : `6af5a67f`.
- **Bibliothèque de test en Release**, admission et adaptateur actifs : `build/astra/lib-53a5a54c-release/` (`b58c19ad…`). Construite avec `MVK_TEST_BUILD_TYPE=Release`, option de test ajoutée par `53a5a54c`. Les bibliothèques de test précédentes étaient en Debug.

**Harnais : un nouveau banc, par décision.** Astra demandait le harnais déjà disponible. J'ai écrit un nouveau banc à HEAD, `PerVertexCostBench.mm` et `run-pervertex-cost-bench.sh` (`c9744291`, `b587007f`, `7cf15dcb`, test seul), pour trois raisons :
- le harnais de `codex/pervertex-performance` est à 239 commits de la branche, et son report entre en conflit (section 7) ;
- `MVK_PERVERTEX_INDIRECT_RECORD_CAPACITY`, qu'il utilisait, a disparu ;
- il ne mesurait pas le coût brut face à un dessin ordinaire : il comparait le TES ordinaire au TES PerVertexKHR, et le PerVertexKHR direct au PerVertexKHR indirect.

**Charge.**
- Une grille de quads sans vertex buffer sur une cible `RGBA8` de 256 × 256, un dessin par command buffer.
- Grille 64 × 64 : 8 192 triangles. Grille 256 × 256 : 131 072 triangles.
- Forme directe (6 sommets par quad) ou indexée (réseau partagé, indices uint32).
- **Deux bras :**
  - « ordinaire » : couleur interpolée ;
  - « pervertex » : les trois valeurs `pervertexEXT` pondérées par `BaryCoordKHR`, donc capture puis rejeu portables.
- Les deux bras donnent la même image à 2/255 près, contrôlé à chaque exécution. Chaque bras est aussi contrôlé stable d'un échantillon à l'autre.

**Mesures par échantillon.**
- `submit` : temps mural de `vkQueueSubmit`. Les soumissions sont synchrones, donc MoltenVK encode pendant cet appel.
- `completion` : `vkQueueSubmit` plus l'attente de la fence.
- `encode` : `commandBufferEncoding.latest` de MoltenVK, c'est-à-dire l'encodage CPU du command buffer.
- `execution` : `mtlCommandBufferExecution.latest`, de la validation Metal du command buffer à son rappel de fin.
- `timestamp` : intervalle entre deux timestamps Vulkan, placés après un remplissage d'ancrage et après la copie.
- Nombre de command buffers Metal par soumission : 1 pour les deux bras, dans tous les cas.

**Mémoire.** Elle est mesurée dans une phase à part : quatre soumissions ordinaires, puis quatre PerVertexKHR. Le harnais relève l'usage des tas (`VK_EXT_memory_budget`, soit `currentAllocatedSize` de Metal) avant, juste après et à la fin de chaque soumission.

**Protocole du runner.**
- Chaque forme passe d'abord sous validation Metal.
- Vient ensuite un calibrage sans ancre.
- Puis trois séries de 100 paires sans validation, après 8 paires d'échauffement. L'ordre des bras alterne à chaque paire et le premier bras change d'une série à l'autre.
- Réglages : `MVK_CONFIG_PERFORMANCE_TRACKING=1`, soumissions synchrones, pas de préremplissage.

## 2. Ce que mesure un timestamp Vulkan sur M4

Sur un GPU Apple, MoltenVK ne peut pas échantillonner un compteur à la frontière d'un dessin ou d'un dispatch. Un timestamp Vulkan est mis en attente, puis pris par un petit encodeur blit à la fermeture de l'encodeur Metal ouvert au moment où il est écrit (`encodeTimestampStageCounterSamples`, appelé par `endCurrentMetalEncoding`).

- Un timestamp écrit quand aucun encodeur n'est ouvert, par exemple juste avant une passe de rendu, est pris avant cette passe.
- Un timestamp écrit pendant qu'un encodeur est ouvert est pris **après** cet encodeur.
- **Conséquence :** un timestamp Vulkan ne peut pas encadrer un seul dessin ni un seul dispatch interne, par exemple une capture PerVertexKHR.
- **Calibrage.** Avec et sans ancre, les intervalles concordent dans la marge de bruit (section 5). C'est attendu, puisque le timestamp de début est écrit avant la passe de rendu, sans encodeur ouvert.

## 3. Mesures nettes

**Encodage CPU (`encode`)**, médianes des trois séries :

| Grille | Forme | Ordinaire | PerVertexKHR | Écart |
| --- | --- | --- | --- | --- |
| 64 | directe | 34,3 / 27,3 / 33,4 µs | 130,9 / 117,3 / 135,4 µs | +90 à +102 µs |
| 64 | indexée | 26,4 / 36,2 / 25,4 µs | 119,2 / 130,5 / 122,1 µs | +93 à +97 µs |
| 256 | directe | 42,7 / 37,4 / 31,2 µs | 1 206 / 1 253 / 1 099 µs | +1 068 à +1 216 µs |
| 256 | indexée | 31,8 / 51,5 / 35,2 µs | 1 120 / 1 294 / 1 171 µs | +1 088 à +1 242 µs |

Le surcoût CPU croît avec le nombre de primitives : environ 9 ns par primitive, en forme directe comme indexée. Pour ces dessins non indirects, MoltenVK remplit les tables de rejeu sur le CPU. `mvkPopulatePerVertexReplay` a un seul site d'appel, `MVKCmdDraw.mm:342`, placé après les deux branches de capture. Cette attribution est déduite du code ; elle n'a pas été profilée.

**Mémoire**, pic au-dessus du niveau d'avant la phase :

| Grille | Ordinaire | PerVertexKHR | Écart | Scratch calculé |
| --- | --- | --- | --- | --- |
| 64 | 720 KiB | 1 872 KiB | **1 152 KiB** | 24 576 enregistrements × 32 o + 24 576 occurrences × 8 o + 8 192 primitives × 12 o + 24 576 coins × 4 o = 1 152 KiB |
| 256 | 720 KiB | 19 152 KiB | **18 432 KiB** | même formule pour 393 216 enregistrements et 131 072 primitives = 18 432 KiB |

- L'écart mesuré égale **exactement** le scratch calculé par les formules de `MVKPerVertexScratch.h`, avec 32 octets par enregistrement capturé (position et couleur).
- En forme indexée, la capture compte un enregistrement par indice, d'où la même taille.
- *(Retiré à la demande d'Astra, section 10 : l'usage global des tas ne prouve pas la libération des buffers de scratch. Les résidus relevés après les deux bras, de 720 KiB à 6,7 MiB, ne sont pas attribués.)*

**Occupation GPU par encodeur**, mesurée par une trace Metal System Trace (`xctrace`) sur 10 paires, grille 256. Le temps d'occupation vertex est stable, avec un écart interquartile de 1 à 30 µs selon l'encodeur ; par exemple 136,7 à 137,7 µs pour la capture directe, et 197,6 à 198,5 µs pour son rejeu :

| Forme | Encodeur | Ordinaire | PerVertexKHR |
| --- | --- | --- | --- |
| directe | rendu (VS) | 143 µs | — |
| directe | capture, dans la première passe de rendu | — | 137 µs de vertex |
| directe | rejeu (« Metal renderpass restart ») | — | 198 µs de vertex, 90 µs de fragment |
| indexée | rendu (VS) | 89 µs | — |
| indexée | **dispatch de capture** (encodeur compute, étiquette « vertex and tess control stages ») | — | **130 µs** (écart interquartile 102 à 150) |
| indexée | rejeu | — | 255 µs de vertex |

- **Le dispatch supplémentaire, mesuré seul : c'est la capture.** En forme directe, c'est une passe vertex dans la première passe de rendu, de coût voisin du VS ordinaire. En forme indexée, c'est un dispatch compute d'environ 130 µs.
- **Le rejeu coûte lui aussi plus en vertex que le VS ordinaire.** Il traite trois sommets par primitive, sans réutilisation, et lit les enregistrements et les tables : 198 µs contre 143 µs en direct, et 255 µs contre 89 µs en indexé.
- Les durées de fragment et les étendues d'encodeur varient d'un facteur 10, sous l'effet des autres clients GPU (section 4). Elles ne sont pas retenues.
- Les étiquettes d'encodeur de MoltenVK sont génériques ; l'attribution repose sur leur position dans le command buffer, sans ambiguïté dans ce banc.

## 4. La charge n'était pas contrôlée

Le runner refuse de démarrer si un autre essai GPU du dépôt tourne, et il relève l'état thermique et les processus les plus actifs avant et après chaque étape. Ce second contrôle a montré, pendant les séries :
- WindowServer (47 à 60 % d'un cœur) ;
- `mediaanalysisd` ;
- Time Machine (`backupd`) ;
- des simulateurs iOS ;
- CBDash, Keypad, Discord.

Aucun avertissement thermique n'a été relevé. Je n'ai pas arrêté ces processus. Conséquences : les médianes GPU et murales varient d'un facteur 2 entre séries, avec des écarts interquartiles larges. La même charge, dans un passage antérieur un peu plus calme (`cost-bench-b587007f`, grille 64 seule), donnait des mesures resserrées :
- `execution` : 270 à 310 µs en ordinaire, 307 à 375 µs en PerVertexKHR ;
- `timestamp` : 11 à 20 µs contre 20 à 52 µs.

## 5. Mesures GPU et murales bruitées (à refaire sous charge contrôlée)

Médianes des trois séries (`cost-bench-7cf15dcb/summary.txt`, avec écarts interquartiles et p95) :

| Grille, forme | `execution` ordinaire | `execution` PerVertexKHR | `timestamp` ordinaire | `timestamp` PerVertexKHR |
| --- | --- | --- | --- | --- |
| 64, directe | 456 / 800 / 427 µs | 571 / 768 / 411 µs | 160 / 603 / 110 µs | 298 / 500 / 110 µs |
| 64, indexée | 326 / 359 / 338 µs | 488 / 745 / 436 µs | 77 / 90 / 92 µs | 154 / 424 / 139 µs |
| 256, directe | 783 / 838 / 681 µs | 1 078 / 1 135 / 894 µs | 324 / 544 / 361 µs | 728 / 915 / 626 µs |
| 256, indexée | 834 / 652 / 516 µs | 1 009 / 1 283 / 943 µs | 513 / 365 / 265 µs | 746 / 947 / 694 µs |

**Calibrage sans ancre** (une série par forme et grille) : 265 µs en ordinaire et 452 µs en PerVertexKHR (256, directe), du même ordre que les séries avec ancre.

## 6. Limites d'attribution

- **`execution`** va de la validation Metal au rappel de fin. Il inclut la latence d'ordonnancement et de rappel, dominante pour une charge légère.
- **`timestamp`** couvre la passe de rendu et la copie, mais ne peut pas isoler un encodeur interne (section 2).
- **Occupations par encodeur.** Seules les occupations vertex de la trace sont stables. Une trace Metal ajoute son propre coût, et elle couvre 10 paires d'une seule exécution.
- **Surcoût CPU.** Son attribution aux tables de rejeu est déduite du code, sans profilage.
- **Mémoire.** Elle compte toute allocation Metal du processus ; l'accord exact avec la formule du scratch l'isole ici.
- **Portée.** Seuls sont couverts un M4 Pro, une bibliothèque Release de test (admission et adaptateur actifs, extension publique fermée), une seule charge, sans multiview, sans redémarrage de primitive, et le sommet provoquant « premier ».

## 7. Ce qui n'est pas fait

**Harnais antérieur.** Il est sur `codex/pervertex-performance` : 4 commits posés sur `490b12b4`, 239 commits derrière la branche. Il compare le TES ordinaire au TES PerVertexKHR, et le PerVertexKHR direct au PerVertexKHR indirect. Il n'a pas été repris, car le report entre en conflit avec l'évolution de `PerVertexIndirectGPUTests.cpp` et de `topology.cpp`. Son rapport cite des chemins `/private/tmp` qui n'existent plus ; il reste un document historique.
- `MVK_PERVERTEX_INDIRECT_RECORD_CAPACITY`, qu'il utilisait, n'existe plus dans le runtime.

**Non mesurés à HEAD.**
- Le dispatch supplémentaire du chemin TES (TES en compute et noyau de topologie).
- Le coût de l'indirect PerVertexKHR.
- Trois séries sous charge contrôlée.
- M1, M3 et Intel.

## 8. Preuves

Chaque dossier de `build/astra/` a son `EVIDENCE.sha256`, et tous les essais tournent sur un arbre propre (`dirty_tests=0`).

| Dossier | Entrées | Contenu |
| --- | --- | --- |
| `lib-53a5a54c-release/` | 4 | Bibliothèque Release |
| `cost-bench-b587007f/` | 38 | Premier passage, grille 64 |
| `cost-bench-7cf15dcb/` | 72 | Deux grilles, 20 étapes, `summary.txt` et `summarize.py` |
| `cost-trace-7cf15dcb/` | 1 223 | Traces Metal System Trace, tables exportées, `encoders.py` et ses résultats |
| `cost-bench-c9744291/` | 9 | Passage interrompu : le relevé de processus échouait sous `pipefail` ; corrigé par `b587007f` |

## 9. Décisions demandées

1. **Charge contrôlée.** Le runner est prêt :

   ```
   bash MoltenVK/Tests/run-pervertex-cost-bench.sh build/astra/lib-53a5a54c-release/build/moltenvk/MoltenVK/libMoltenVK.1.4.3.dylib <dossier> 100
   ```

   Il faut d'abord fermer les applications actives et les simulateurs, et suspendre Time Machine. Cela revient à l'utilisateur.
2. **TES et indirect.** Faut-il les mesurer à HEAD ? Cela demande de reporter les deux bancs antérieurs sur la branche courante, ou d'étendre ce banc.

## 10. Corrections demandées par Astra (`c2aeaab9`)

- **Différences appariées.** Pour chaque mesure, le banc donne aussi la différence PerVertexKHR moins ordinaire à l'intérieur d'une même paire (médiane, quartiles, p95). La charge partagée par la paire s'annule.
- **`heapUsage()` hors des échantillons chronométrés.** Au premier passage, un appel se trouvait entre `vkQueueSubmit` et l'attente de la fence, donc dans `completion`. La mémoire n'est plus mesurée que dans la phase mémoire.
- **Libération du scratch.** L'affirmation « scratch libéré dans 23 exécutions sur 24 » est retirée (section 3).
- **Intel est annulé.** M1 et M3 restent pour la fin. Le candidat SPIRV-Cross `+ 0.5` reste isolé.

## 11. Séries dans la fenêtre calme choisie par l'utilisateur (`build/astra/cost-bench-c2aeaab9/`)

**Charge.** L'utilisateur avait quitté les simulateurs, CBDash, Discord et Keypad, et suspendu Time Machine. La contention restait sensible :
- `mediaanalysisd`, service système d'analyse des photos, à 93–102 % d'un cœur ;
- un processus `/usr/bin/log`, que je n'ai pas lancé, à 99 % ;
- WindowServer à 41–45 %.

**Différences appariées**, médiane et quartiles des trois séries :

| Grille, forme | `encode` | `execution` | `timestamp` |
| --- | --- | --- | --- |
| 64, directe | +104 / +97 / +101 µs (IQR ≈ 80..118) | +46 / +45 / +43 µs (IQR ≈ 25..72) | +31 / +24 / +25 µs (IQR ≈ −5..58) |
| 64, indexée | +108 / +105 / +103 µs | +56 / +65 / +55 µs | +46 / +58 / +63 µs |
| 256, directe | +1 050 / +1 040 / +1 038 µs (IQR ≈ 987..1 101) | +498 / +482 / +249 µs | +454 / +437 / +205 µs |
| 256, indexée | +1 039 / +1 053 / +1 051 µs | +290 / +259 / +517 µs | +241 / +231 / +465 µs |

- **Encodage CPU : reproductible.** Environ +100 µs sur la grille 64 et environ +1 045 µs sur la grille 256, avec des quartiles serrés dans toutes les séries.
- **L'estimation d'environ 9 ns par primitive** reste une estimation sur deux tailles.
- **GPU, grille 64 : cohérent** d'une série à l'autre.
- **GPU, grille 256 : bimodal**, environ +250 µs ou environ +480 µs selon la série. Il n'est pas qualifié.

## 12. Indirect et indirect indexé (`build/astra/cost-bench-indirect-73b71fd8/`)

**Montage.**
- Formes `indirect` et `indexed-indirect` du même banc (`73b71fd8`), avec une commande indirecte écrite une fois.
- Validation Metal réussie pour chaque forme et chaque grille.
- Deux séries par grille, en ordre alterné.
- Charge : `mediaanalysisd` à 50–80 %, WindowServer à 35–44 % ; `/usr/bin/log` avait disparu.

**Différences appariées**, deux séries :

| Grille, forme | `encode` | `execution` | `timestamp` | Mémoire, pic au-dessus de l'ordinaire |
| --- | --- | --- | --- | --- |
| 64, indirecte | +363 / +368 µs | +49 / +76 µs | +412 / +441 µs | +384 KiB |
| 64, indexée indirecte | +373 / +373 µs | +98 / +93 µs | +486 / +494 µs | +480 KiB |
| 256, indirecte | +793 / +962 µs | +558 / +557 µs | +1 362 / +1 545 µs | +6 144 KiB |
| 256, indexée indirecte | +927 / +768 µs | +734 / +244 µs | +1 655 / +1 030 µs | +7 680 KiB |

**Lecture.**
- **Deux command buffers.** Une soumission PerVertexKHR indirecte en compte deux : le plan GPU, puis le rejeu. L'ordinaire n'en a qu'un.
- **Ce que couvrent les mesures.**
  - `encode` inclut l'attente CPU du plan GPU, puisque les soumissions sont synchrones.
  - L'intervalle `timestamp` couvre les deux command buffers, aller-retour CPU compris.
  - `execution` ne mesure que le dernier command buffer.
  - Ces trois mesures ne sont donc pas comparables à celles des formes directes.
- **Mémoire.** Le pic PerVertexKHR indirect est plus bas que celui du direct. Il n'est pas attribué : le scratch indirect est dimensionné sur le plan, et le moment de l'échantillonnage peut manquer une partie de sa vie.

**Trace par encodeur** (grille 256, 10 paires, `build/astra/cost-trace-indirect-73b71fd8/`, quartiles serrés) :

| Encodeur | Indirect ordinaire | Indirect PerVertexKHR | Indexé indirect ordinaire | Indexé indirect PerVertexKHR |
| --- | --- | --- | --- | --- |
| Premier command buffer : plan (compute) | — | 16,5 µs | — | 16,9 µs |
| Second command buffer : compute avant le rejeu | — | 97,5 µs | — | 385 µs |
| Rendu ou rejeu, vertex | 326 µs | 783 µs | 161 µs | 462 µs |
| Rendu ou rejeu, fragment | 166 µs | 184 µs | 147 µs | 179 µs |

Les étiquettes sont génériques (« convert indirect buffers », « vertex and tess control stages ») ; l'attribution repose sur la séquence des command buffers. Ces durées ne se comparent qu'à l'intérieur de cette trace : la trace directe de la section 3 a été prise sous une autre charge.

## 13. Témoin TES (`build/astra/tes-trace-73b71fd8/`)

**Montage.**
- Le harnais courant `PerVertexTES/topology.cpp`, compilé contre la bibliothèque Release, avec les shaders de `final-r7-fb3970cc` (les sources TES n'ont pas changé depuis `fb3970cc`).
- Scénario `f3` : deux patchs de niveau 3, rendus par le pipeline ordinaire et par le pipeline PerVertexKHR.
- `TES_TOPOLOGY PASS` sous validation Metal, puis une trace sans validation.

**Encodeurs** (écarts entre soumissions de quelques µs) :

| | TES ordinaire (3 soumissions) | TES PerVertexKHR (6 soumissions) |
| --- | --- | --- |
| Command buffers Metal par soumission | 1 | 2 |
| Compute « vertex and tess control stages » | 18,5 à 19,1 µs | 66,0 à 70,8 µs, en fin de premier command buffer |
| Second compute | — | 9,0 à 10,8 µs, en début de second command buffer |
| Rendu ou rejeu | vertex environ 11 µs, fragment environ 11 µs | vertex environ 12 µs, fragment environ 13 µs |

**Le dispatch supplémentaire du chemin TES :** environ +50 µs sur l'encodeur compute, plus un second compute d'environ 10 µs, et une coupure en deux command buffers. La trace ne sépare pas les dispatchs à l'intérieur d'un même encodeur. La charge est minuscule, deux patchs : ce n'est qu'un témoin.

## 14. Conclusion de ce lot

- **Coût CPU d'encodage : observé et reproductible** dans les séries appariées (section 11).
- **Mémoire.** Le pic mesuré en direct égale le scratch calculé. Les résidus ne sont pas attribués.
- **Coût GPU : non qualifié.** La contention a persisté dans la fenêtre choisie (`mediaanalysisd`, `/usr/bin/log`), et la grille 256 reste bimodale. Selon la consigne d'Astra, **les répétitions s'arrêtent ici**.
- **Encodeurs.** Les traces isolent la capture et les dispatchs supplémentaires des chemins direct, indexé, indirect et TES. Ce sont des mesures exploratoires, sur une seule exécution chacune.

**Preuves supplémentaires** (chaque dossier de `build/astra/` a son `EVIDENCE.sha256`) :

| Dossier | Entrées |
| --- | --- |
| `cost-bench-c2aeaab9/` | 70 |
| `cost-bench-indirect-73b71fd8/` | 46 |
| `cost-trace-indirect-73b71fd8/` | 1 200 |
| `tes-trace-73b71fd8/` | 632 |
