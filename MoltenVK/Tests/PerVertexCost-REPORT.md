# PerVertexKHR portable : coût face à un dessin ordinaire sur M4 (30 septembre 2026)

Premier passage du chantier de mesure demandé par Astra. Aucune optimisation, aucune nouvelle admission. **La charge de fond n'était pas contrôlée** (section 4) : les mesures GPU de ce passage sont exploratoires. Les mesures CPU, mémoire et par encodeur sont nettes.

## 1. Ce qui est mesuré, et sur quoi

**Machine et outils.** Apple M4 Pro, macOS 27.2 (26B5091g), Xcode 27.1 (27A9269).

**Code mesuré.**
- MoltenVK : runtime de `fb3970cc`, sans changement depuis.
- SPIRV-Cross : `6af5a67f`.
- **Bibliothèque de test en Release**, admission et adaptateur actifs : `build/astra/lib-53a5a54c-release/` (`b58c19ad…`). Construite avec `MVK_TEST_BUILD_TYPE=Release`, option de test ajoutée par `53a5a54c`. Les bibliothèques de test précédentes étaient en Debug.

**Harnais.**
- `PerVertexCostBench.mm` et `run-pervertex-cost-bench.sh` (`c9744291`, `b587007f`, `7cf15dcb`), test seul.
- Le harnais antérieur de `codex/pervertex-performance` n'est pas repris (section 7).

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

Le surcoût CPU croît avec le nombre de primitives : environ 9 ns par primitive. Pour les dessins directs, cela correspond aux tables de rejeu remplies sur le CPU par `mvkPopulatePerVertexReplay`. Cette attribution est déduite du code ; elle n'a pas été profilée.

**Mémoire**, pic au-dessus du niveau d'avant la phase :

| Grille | Ordinaire | PerVertexKHR | Écart | Scratch calculé |
| --- | --- | --- | --- | --- |
| 64 | 720 KiB | 1 872 KiB | **1 152 KiB** | 24 576 enregistrements × 32 o + 24 576 occurrences × 8 o + 8 192 primitives × 12 o + 24 576 coins × 4 o = 1 152 KiB |
| 256 | 720 KiB | 19 152 KiB | **18 432 KiB** | même formule pour 393 216 enregistrements et 131 072 primitives = 18 432 KiB |

- L'écart mesuré égale **exactement** le scratch calculé par les formules de `MVKPerVertexScratch.h`, avec 32 octets par enregistrement capturé (position et couleur).
- En forme indexée, la capture compte un enregistrement par indice, d'où la même taille.
- Après les deux bras, le niveau revient à celui de l'ordinaire (720 KiB) : **le scratch n'est pas conservé** après la fin du dessin.

**Occupation GPU par encodeur**, mesurée par une trace Metal System Trace (`xctrace`) sur 10 paires, grille 256. Le temps d'occupation vertex est stable (écart interquartile de 1 à 2 µs) :

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
