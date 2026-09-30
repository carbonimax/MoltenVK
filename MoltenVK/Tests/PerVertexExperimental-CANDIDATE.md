# PerVertexKHR expérimental : définition du candidat, étape 1 (30 septembre 2026)

Jalon revu favorablement par Astra : livrer un **candidat reproductible du fork existant**, sans revendiquer le support
complet ni la conformité publique de `VK_KHR_fragment_shader_barycentric`. Ce document est l'étape 1 du chemin : il
fixe les SHA, les dépendances et outils, la configuration, le périmètre qualifié et une **liste fermée de tests
existants**. Rien n'est construit ni exécuté ici. K1/K2 (#2851, #2852) ne bloquent pas ce chemin ; l'extraction K4
est différée ; TES, soumission et perte restent gelés ; FB25000318 n'appelle aucune investigation ; `+ 0.5` reste
isolé ; qualification finale sur M1 et M2.

## 1. SHA

| Élément | Valeur |
|---|---|
| Runtime MoltenVK | `fb3970cc` (dernier commit touchant `MoltenVK/MoltenVK`, `MoltenVKShaderConverter`, `ExternalRevisions`, CMake ou l'adaptateur). `git diff fb3970cc a2798c31` sur ces chemins est vide. |
| Source du candidat | le commit du fork qui fige ce document ; son runtime doit rester identique à `fb3970cc`, vérifié à la construction |
| SPIRV-Cross | `6af5a67f` (fork : 25 commits sur `aa217aeb`, dont TES, mesh et natif, gardés tels quels) |
| SPIRV-Tools | `0d6fd73c` |
| Volk | `77689330` |
| Vulkan-Headers | `e3b1eec0` |
| Vulkan-Tools | `8c66b352` |
| cereal | `a56bad8b` |

## 2. Outils (hôte de construction M4)

Apple M4 Pro, macOS 27.2 (26B5091g), Xcode 27.1 (27A9269), CMake 4.4.3, Ninja 1.13.2, glslangValidator 11:16.6.0,
spirv-val (SPIRV-Tools v2026.3), GNU timeout 9.11, Python 3.12.8. CTS : VK-GL-CTS `vulkan-cts-1.4.6.2` (`f6a2970`),
`deqp-vk` (77 Mo) et ses données (17 Mo), mustpass `main/vk-default`.

## 3. Configuration du candidat

- **Driver existant :** `MoltenVK/Tests/PerVertexTES/build-library.sh <sortie> OFF ON` : **admission TES OFF**,
  adaptateur de test **lié**, Debug arm64 (configuration de toutes les preuves antérieures ; Release n'est pas qualifiée),
  **`MVK_USE_METAL_PRIVATE_API` OFF** (valeur par défaut de CMake, à vérifier dans `CMakeCache.txt`).
- **Lancé depuis la racine du fork :** le CMake de MoltenVK grave dans `mvkRevString` le `git rev-parse --short HEAD`
  du dossier courant ; la révision embarquée doit être celle du candidat.
- **Activation expérimentale explicite :** l'application appelle `mvkEnableTESFixtureDevice(VkPhysicalDevice)`
  (recherché par `dlsym`). Sans cet appel, l'extension reste fermée (`MVKDevice.mm:3632-3636`).
- **Contenu de test assumé :** la bibliothèque exporte aussi les crochets de test de `EnableTestDevice.mm`
  (`mvkTestMarkDeviceLost`, `mvkTestLimitMetalBufferSize`, compteurs). C'est une bibliothèque expérimentale, pas une
  bibliothèque de distribution.
- **Identité vérifiée (étape 2) :** empreinte de la bibliothèque contre `PROVENANCE.txt` ; `mvkRevString` = SHA court
  du candidat ; à l'exécution, les 4 premiers octets de `VkPhysicalDeviceProperties::pipelineCacheUUID` (révision git,
  `MVKDevice.mm:3347`) ; `DYLD_PRINT_LIBRARIES` pour la bibliothèque réellement chargée, comme le fait déjà
  `MacFamilyHarness/run.sh`.

## 4. Périmètre qualifié

**Qualifié par la liste fermée (section 5), sur la bibliothèque candidate :**
- étages vertex et fragment en SPIR-V, chemin portable capture puis rejeu ;
- entrées `PerVertexKHR` : scalaires et vecteurs `float`, `int`, `uint` ; tableaux ; structures ; interpolations
  `per_vertex`, `per_vertex_flat`, `per_vertex_interp` des cas CTS ;
- `BaryCoordKHR` et `BaryCoordNoPerspKHR` portables, **pour les triangles seulement** ;
- topologies simples : points, listes et bandes de lignes, listes, bandes et éventails de triangles, statiques et
  dynamiques (`VK_DYNAMIC_STATE_PRIMITIVE_TOPOLOGY` dans la classe de la topologie du pipeline) ;
- `vkCmdDraw` et `vkCmdDrawIndexed` (index uint32), avec `firstVertex` ou `firstIndex` non nul et `firstInstance` 2 ou
  3 (oracle B : une instance, `vertexOffset` nul) ;
- `ClipDistance` écrit par le vertex shader (cas CTS `clip`) ;
- un échantillon, rastérisation remplie, sommet provoquant premier, sans multiview ;
- mélange alpha, qui rend l'ordre des dessins visible (oracle B) ;
- refus avant soumission des attachements memoryless importés à travers la séparation capture/rejeu.

**Admis par le runtime mais sans preuve GPU dans la liste fermée (non qualifiés dans ce jalon) :**
- plusieurs instances et `vertexOffset` non nul : aucun cas de la liste fermée ne les exerce de façon identifiée ;
- redémarrage de primitive et index uint8 ou uint16 : preuves hôte (`host-restart`, `host-topology`) ; leurs preuves
  GPU historiques passent par le programme indirect, qui enchaîne toujours un dessin indirect (hors périmètre) ;
- command buffers secondaires et préremplissage Metal : preuves hôte (`host-prefill`) seulement ;
- un `viewMask` d'une seule vue : aucune preuve dans la liste fermée.

**Hors périmètre, code et preuves conservés sans reprise :** indirect et indirect Count, TES, mesh, natif Apple10,
MSAA, multiview à plusieurs vues, sommet provoquant dernier, `polygonMode` autre que `FILL`, API privée ON, adjacence.
**Pour les points et les lignes, aucun poids barycentrique défini n'est promis.**

## 5. Liste fermée de tests

Toutes les exécutions GPU se font sous validation Metal (`MTL_DEBUG_LAYER=1`, `MTL_SHADER_VALIDATION=1`), une charge
GPU à la fois. **Un saut ou un `NotSupported` dans une liste attendue « Pass » est une absence de preuve, pas une
réussite.** Toute sortie différente de l'attendu arrête la qualification.

| Réf. | Test existant | Commande | Attendu (référence `final-r7-fb3970cc`) |
|---|---|---|---|
| A | 8 suites hôte : `prefill`, `helper-preflight`, `scratch`, `draw-size`, `restart`, `topology`, `capture-variant`, `memoryless` | `run-pervertex-<suite>-tests.sh <sortie>` | PASS chacune |
| B | Oracle de topologie dynamique, 14 cas : `triangles:{direct,indexed}:{pervertex,ordinary,weights,weights-w,weights-w-noperspective}`, `lines:{direct,indexed}:{pervertex,ordinary}` | `run-pervertex-dynamic-topology-tests.sh <lib> <sortie> 0 <cas>…` | PASS chacun |
| C | Séparation capture/rejeu, variantes `memoryless-depth`, `memoryless-stencil` | `run-pervertex-split-tests.sh <lib> <sortie> after memoryless-depth memoryless-stencil` | REFUSED (sortie 4) chacune |
| D | CTS `fragment_shading_barycentric`, périmètre minimal : **1 201 cas** (`experimental-vsfs-barycentric.txt`, sha256 `58e51b2a…`, produit par `PerVertexCTS/select-experimental-scope.py` depuis `barycentric-runnable.txt`, `18c82875…`) | `run-pervertex-cts.sh <cts> <lib> <liste> <sortie> validated` | **1 201 Pass** (1 201/1 201 à `final-r7`) |
| E | CTS ordinaire, topologies et éventails : 562 cas (`ordinary-fan-topology.txt`, `e814c9d5…`) | idem | ensembles identiques à `final-r7` : 258 Pass, 299 NotSupported, 5 Fail `VK_ERROR_FEATURE_NOT_PRESENT` (`*_bind_unused_ms`) |
| F | Garde publique : la liste D sans adaptateur | `PERVERTEX_CTS_DIRECT=1 run-pervertex-cts.sh … validated` | 0 Pass, 0 Fail, 1 201 NotSupported |
| G | Identité : empreinte, `mvkRevString`, `pipelineCacheUUID`, bibliothèque chargée | étape 2 | égalité avec le candidat |

Composition de D : 1 176 cas de données (588 statiques, 588 dynamiques, dont 168 avec `ClipDistance`), 24 cas de poids
sur triangles (18 statiques, 6 dynamiques mono-échantillon), 1 cas `pervertex_correctness`. Exclus des 2 851 cas
exécutables : 744 adjacence, 690 mesh, 108 sommet provoquant dernier, 50 MSAA, 36 tessellation, 22 poids sur points et
lignes.

**Hors liste (preuves historiques conservées, non relancées) :** matrice indirecte, continuation, suites de perte,
TES, mesh, poids MSAA, multiview, suites hôte `indirect-kernel`, `indirect`, `multiview*`, `handler-tracking` et
`commit-sites` (volet perte), banc de coût.

## 6. Coût

Le rapport existant `PerVertexCost-REPORT.md` fait foi : coût CPU mesuré, **coût GPU non qualifié**. Il a été mesuré
sur une bibliothèque Release avec admission, pas sur le candidat Debug : aucune nouvelle mesure ni optimisation.

## 7. Étape 2 à venir (bundle)

Le bundle M1/M2 existant (`MacFamilyHarness`, r14) vise l'indirect, le TES et le mesh. Pour ce jalon, il devra être
consolidé en une variante réduite : bibliothèque candidate, sonde d'identité et de garde, programme de l'oracle B et
ses shaders, programme C, et, selon décision, `deqp-vk` avec les listes D, E, F (environ 100 Mo). Hors ligne, sans
Xcode, comme r14.

## 8. Décisions demandées

1. Configuration : Debug arm64, comme les preuves antérieures (recommandé), ou Release.
2. Redémarrage et index uint8/uint16 : les laisser non qualifiés dans ce jalon (recommandé), ou ajouter au programme
   GPU existant un mode direct seul, ce qui retouche un test de l'indirect.
3. CTS dans le bundle M1/M2 : oui (recommandé ; preuve la plus forte), ou oracles seuls.
