# Topologie TES PerVertexKHR générée sur GPU : rapport de jalon (M4 Pro, 27 septembre 2026)

Rapport destiné au fil principal, pour revue avant intégration. Rien n'a été poussé ni publié, et aucune PR ou commentaire n'a été créé. Je n'ai touché ni au checkout principal, ni au SPIRV-Cross partagé, ni aux worktrees indirects, ni à `/private/tmp/pervertex-integrated-20260927`, ni au plan. La branche indirecte n'est pas fusionnée. La garde publique reste fermée. Ce fichier n'est pas suivi par git.

## Verdict

**Jalon initial (`f2c75069`, 58/58)** : topologie TES générée sur GPU à partir des facteurs float32 écrits par le TCS ; triangles, `equal_spacing`, `cw`/`ccw`, niveaux uniformes 1, 2 et 3 ; refus déterministe des autres modes.

**Revue indépendante : trois défauts confirmés contre la spécification, reproduits, corrigés.** Chacun a une preuve d'échec avant correction et de réussite après :

| # | Défaut | Règle Vulkan | Avant (`a56eaad6`) | Après |
| --- | --- | --- | --- | --- |
| 1 | `gl_PrimitiveID` du fragment = index du triangle rejoué | `interfaces.adoc`, PrimitiveId : sans géométrie, le fragment reçoit la valeur du TES, l'index du patch | 2 875 pixels faux sur 3 136 (`mixed`), 3 018 (`f3`) | 0 pixel faux |
| 2 | Coordonnées float32 des niveaux 2 et 3 hors invariance | `invariance.adoc`, règles 3, 4 et 8 | règle 8 violée (6 à 24 composantes), règle 3 violée au niveau 3 (12 sommets), raccord `seam3` inégal | règles 3, 4 et 8 respectées ; coordonnées **identiques bit à bit** au tessellateur M4 |
| 3 | `vkCmdDraw` de 1 ou 2 sommets saute le VS | `shaders.adoc` : VS exécuté au moins une fois par sommet du dessin | compteur SSBO 0 au lieu de 1 et 2 | 1 et 2, comme le pipeline ordinaire |

**Matrice complète : 72/72 sous validation Metal API/GPU** sur `c3c42e31` (58 cas avant, 14 cas ajoutés). Oracles ordinaires : 8 images reproduites octet par octet. Tests hôtes : tous verts.

**Admission non élargie.** Les niveaux admis restent uniformes 1 à 3. Le défaut 2 n'a pas demandé de réduction : un générateur conforme existe, et il est prouvé.

## Départ et isolation

| Élément | Valeur |
| --- | --- |
| Départ de cette passe | MoltenVK `f2c75069`, SPIRV-Cross `bfbde51d` (worktrees isolés, branche `claude/pervertex-tes-gpu-topology`) |
| HEAD MoltenVK | `790cacf80163870db47cc578054eba6511e0bd21` |
| HEAD SPIRV-Cross | `8de8010424a29b577c984437dccaa422b6462e9c`, **commit local non public**, pin mis à jour dans `ExternalRevisions/SPIRV-Cross_repo_revision` |
| Départ du jalon | MoltenVK `d608d84c` + WIP TES du checkout partagé ; SPIRV-Cross `4308267d` + WIP float32/TES compute, importés sans modification (manifestes `build/tes-topology/import/`) |

**Commits de cette passe** (au-dessus de `f2c75069`) :

| SHA | Contenu |
| --- | --- |
| `5a385cee` | **tests seuls** : PrimitiveID fragment, coordonnées et raccords, dessins de 1/2/4/5 sommets ; TES en espace pixel entier ; runner étendu |
| `9c6f8632` | défaut 3 : VS exécuté pour tout dessin, TCS/générateur/TES/replay seulement pour les patches complets |
| `31911956` | défaut 2 : coordonnées du tessellateur M4 (pas de 1/65536) dans le générateur ; mutation intérieure du runner adaptée |
| `30b88dc1` | défaut 1 : table patch-par-triangle dans le plan, liée au fragment ; pin SPIRV-Cross `8de80104` ; padding Cereal attendu 162 → 158 |
| `3b76c037` | correction de mon oracle de coordonnées : patches éliminés par culling selon l'enroulement |
| `c3c42e31` | README : garanties de coordonnées, PrimitiveID et dessins partiels ; **matrice finale exécutée sur ce SHA** |
| `790cacf8` | test du convertisseur : mutation d'identité de cache pour le nouveau champ ; aucun changement de bibliothèque (`git diff c3c42e31 790cacf8` : un seul fichier de test) |

**Commit SPIRV-Cross** `8de80104` (sur `bfbde51d`) : `MSLPerVertexInputBinding::primitive_id_buffer_index`, test `tests-other/msl_tese_compute.cpp` et fixture `msl_tese_pervertex_primitive.frag`.

`30b88dc1` a été amendé une fois avant toute preuve, pour ajuster le padding Cereal. Sans cela, la bibliothèque s'arrêtait sur l'assertion `mvkValidateCeralArchiveDefinitions`, car le nouveau champ occupe un ancien remplissage.

## Défaut 1 : `gl_PrimitiveID` du fragment

**Règle.** Dans le TCS et le TES, PrimitiveId est l'index du patch dans le dessin. Dans le fragment, sans shader de géométrie ni de maillage, il vaut « the value that would have been presented as input to the geometry shader », c'est-à-dire celui du TES.

**Reproduction.** `primitive-id.frag` lit des entrées `pervertexEXT` (chemin PerVertex) et écrit `gl_PrimitiveID` exactement en rouge. L'attendu vient de la capture de coordonnées au même pixel, dont l'identifiant de patch est vérifié par ailleurs contre le TES matériel.

- Avant : `mixed` donne 2 875/3 136 pixels faux (triangles 6 à 18 au lieu du patch 2) ; `f3` en donne 3 018. `f1` passe, car un patch n'y contient qu'un triangle.
- Le chemin ordinaire (Metal `[[primitive_id]]` post-tessellation) donne déjà le bon patch : `ordinary_wrong=0` partout.

**Correction.**

- **SPIRV-Cross.** Nouveau champ optionnel `primitive_id_buffer_index`. S'il est défini et que le fragment lit PrimitiveId, le point d'entrée prend `const device uint* spvPerVertexPrimitiveIds` et `gl_PrimitiveID = spvPerVertexPrimitiveIds[in.spvPerVertexPrimitive]`. Sans le champ, ou sans lecture de PrimitiveId, le MSL généré est identique (vérifié par le test). L'index doit être dans [0, 30] et distinct des deux tampons PerVertex.
- **MoltenVK.**
  - Le générateur écrit l'index de patch de chaque triangle dans le plan, après les offsets. Cette zone est alignée sur 256 octets (`mvkPerVertexTessPrimitiveIdOffset`) et compte 13 mots par patch au plus.
  - Les pipelines TES lient cette table au slot fragment implicite 6. Le champ entre dans l'identité de cache du convertisseur (`matches`, `serialize`).
  - Les pipelines PerVertex non TES ne le définissent pas. Leur MSL est donc inchangé par construction : c'est vérifié par le test SPIRV-Cross (sortie identique sans le champ) et par le test du convertisseur. Aucun test GPU PerVertex non TES n'a été relancé dans ce worktree.

## Défaut 2 : coordonnées de tessellation

**Règles** (`invariance.adoc`, invariance de tessellation) :

- **Règle 3** : un sommet `(x, 1-x, 0)` implique un sommet exactement `(1-x, x, 0)`, de même sur les deux autres arêtes.
- **Règle 4** : la subdivision d'une arête ne dépend pas de l'arête.
- **Règle 8** : pour toute composante `x`, `1.0 - x` calculé dans le TES est exact. Les valeurs qui échouent ne doivent pas servir de coordonnées.

**Diagnostic.**

- `float(1/3)` = `0x3EAAAAAB` = 11184811·2⁻²⁵, donc `1 - x` = 22369621·2⁻²⁵ n'est pas représentable : la règle 8 est violée.
- Au niveau 3, `float(2/3)` ≠ `1 - float(1/3)`, et `2/9` et `1 - 2t` ont le même défaut : règles 3 et 8 violées.

**Mesure du matériel.** Un TES ordinaire (descripteurs permis hors PerVertex) ajoute ses `gl_TessCoord` à un SSBO (`capture-*.tese`). Le M4 produit des coordonnées en virgule fixe 2⁻¹⁶ (`build/tes-topology/hardware-coordinates/coordinates.txt`, SHA-256 `1d27d0c8…`) :

- niveau 2 : arêtes 0.5, centre (21845, 21845, 21846)/65536 ;
- niveau 3 : arêtes 21845/65536 et 43691/65536 (= 1 − 21845/65536) ;
- intérieurs asymétriques : (36409, 14564, 14563), (14563, 36409, 14564), (14563, 14563, 36410)/65536.

Tous sont multiples de 2⁻¹⁶ : complément exact et miroirs exacts. La capture a été faite avec la bibliothèque « avant » `a56eaad6`. Elle ne dépend pas du correctif : le pipeline ordinaire n'emprunte pas le chemin PerVertex, et la matrice finale retrouve les mêmes coordonnées matérielles.

**Oracles.**

- `coords.frag` stocke, par pixel, les bits des trois sommets PerVertex : patch, `u,v,w`, position.
- Le TES évalue la position à partir de points de contrôle entiers en pixels, puis convertit en NDC. Produits et sommes sont exacts pour des coordonnées dyadiques, donc un raccord ne dépend que des coordonnées, pas de l'ordre d'évaluation ni de la contraction FMA.
- Contrôles :
  - règle 8 et règle 3 sur toutes les coordonnées PerVertex ;
  - ensemble complet de sommets par patch rendu (3, 7 ou 12) ;
  - égalité bit à bit, coordonnées **et positions**, avec le tessellateur matériel ;
  - pour `seam1/2/3`, deux patches partagent l'arête (60,60)-(32,4) : arête `u = 0` du premier, arête `w = 0` du second, parcourues en sens inverse (règle 4). Les positions de l'arête doivent être égales bit à bit.

**Avant** (`defects-before`) :

- `f2` : `inexact_complement=6`, 2 coordonnées ≠ matériel ;
- `f3`/`seam3` : `inexact_complement=24`, `asymmetric_edge=12`, 18 coordonnées ≠ matériel, raccord `seam3` inégal ;
- `seam2` : raccord égal (0.5 est exact), mais règle 8 violée par le centre ;
- le matériel respecte toutes les règles.

**Correction.** Le générateur émet les coordonnées matérielles (`k * q`, `q = 1/65536`). **Après** : 0 composante inexacte, 0 arête asymétrique, 0 écart de coordonnée ou de position avec le matériel, raccords égaux aux niveaux 1, 2 et 3 dans les deux enroulements.

## Défaut 3 : dessins sans patch complet

**Règle.** Le VS est exécuté au moins une fois pour chaque sommet spécifié par la commande (`shaders.adoc`).

**Reproduction.** `resources.vert` incrémente un compteur SSBO. Scénarios `vertices1`, `vertices2`, `vertices4` et `vertices5`.

**Avant** : compteur PerVertex 0 pour 1 et 2 sommets, alors que l'ordinaire donne 1 et 2. Les cas 4 et 5 donnaient déjà 4 et 5.

**Correction.** `recordPerVertexTessEvalDraw` réserve la sortie VS pour tout dessin. Il ne réserve invocations, TCS, niveaux et plan que pour les patches complets. `encodePerVertexTessEval` exécute le VS, puis rouvre la passe de rendu s'il n'y a aucun patch.

**Après** : compteurs 1, 2, 4, 5 identiques à l'ordinaire, 0 pixel PerVertex, écriture antérieure préservée.

## Preuves

Toutes sous `MoltenVK-tes-topology/build/tes-topology/` (non suivi), avec `MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1`, sans aucune erreur de validation :

| Dossier | Tests / bibliothèque | Résultat |
| --- | --- | --- |
| `defects-before/` | tests `5a385cee`, bibliothèque dev `a56eaad6` (construite depuis `7b0ecdda`, sources de bibliothèque identiques à `f2c75069`) | 2/13 passent (`f1`, `seam1`) ; les 11 autres échouent sur les trois défauts |
| `defect3-after/` | `9c6f8632`, `2eb568b2…` | `vertices1/2` passent dans les deux enroulements ; les échecs restants sont les défauts 1 et 2 |
| `defect2-after/` | `31911956`, `f203a996…` | règles 3, 4, 8 et égalité matériel partout ; seul le défaut 1 reste |
| `defects-after/` | `30b88dc1`, `5693578e…` | 13/13 |
| `others-after/`, `cull-after/` | `30b88dc1` / `3b76c037` | `cull ccw` échouait par **erreur de mon oracle** (patch miroir supposé toujours éliminé) ; corrigé dans `3b76c037`, puis 2/2 |
| **`final-c/`** | **`c3c42e31`**, SPIRV-Cross `8de80104`, 6 bibliothèques reconstruites depuis `HEAD` | **72/72**, `EVIDENCE.sha256` 487/487, `SOURCE-INDEX.txt`, dumps MSL float32 |
| `ordinary-oracles-c/` | shipping `52faa953…` | 8 images identiques octet par octet, `EVIDENCE.sha256` 38/38 |
| `host-c/` | sources `790cacf8` | helper-preflight, scratch, draw-size, restart, prefill, indirect CPU, memoryless, topology, Cereal, convertisseur (11 mutations d'identité de cache dont `primitive_id_buffer_index`) : tous PASS |

Chaque dossier `defect*`/`*-after` contient `PROVENANCE.txt`, `summary.txt`, les journaux et `EVIDENCE.sha256`. La matrice `final-c` couvre, dans les deux enroulements :

- les 58 cas du jalon ;
- `seam1`, `seam2`, `seam3` ;
- `vertices1`, `vertices2`, `vertices4`, `vertices5`.

Les nouveaux oracles (coordonnées, PrimitiveID) tournent aussi dans tous les scénarios rendus existants.

**Mutations du générateur**, reconstruites depuis `HEAD` et toutes détectées :

| Mutation | Détection |
| --- | --- |
| Enroulement inversé | 4 704 pixels de couverture sous culling ; modèle CPU (56 écarts de canal) |
| Intérieur du niveau 3 (14563 → 16384) | 2 050 pixels de valeurs ; modèle CPU ; 6 coordonnées ≠ matériel |
| Offsets de patch ignorés | 710 pixels de couverture |

**SPIRV-Cross `8de80104`.**

- `ctest -R spirv-cross-msl` : 15/15 (`build/tes-topology/spirv-cross-ctest-msl-8de80104.log`).
- `msl_tese_compute.sh` : 9 vérifications de syntaxe Metal, dont le nouveau fragment, plus le rendu GPU existant. Ces vérifications utilisent `xcrun metal … -fsyntax-only`, qui fonctionne ici (Apple metal 32023.921). Contrôle : le même appel sur une copie du fragment avec une erreur injectée échoue (code 1, « expected expression »).
- Les suites CTest `spirv-cross-test-metal*` et `-ue4*` échouent sur ce Mac pour une raison d'environnement. `test_shaders.py` compile avec `xcrun --sdk macosx|iphoneos metal`, qui exige le composant téléchargeable MetalToolchain, absent : « cannot execute tool 'metal' due to missing Metal Toolchain ». Je les ai donc relancées avec `--force-no-external-validation` (comparaison aux références sans compilation Metal) : `shaders-msl`, `shaders-msl --opt` et `shaders-ue4` (3 variantes) passent.
- `shaders-msl-no-opt` échoue sur `tese/load-clip-cull.msl2.tese`, **à l'identique sur la base `bfbde51d`** : c'est un défaut préexistant du WIP TES importé. La CLI n'expose pas le nouveau champ, donc aucune référence ne peut changer.

**Bibliothèques de la matrice finale** (Debug arm64, `final-c/*/PROVENANCE.txt`, `dirty_files=0`) :

| Build | SHA-256 |
| --- | --- |
| dev | `59e2f1b3077b4e149a021d71e8354adecb8d1bedff2b68a15fd463426b9e37ea` |
| sans admission | `a69aa61424e45e299e5a8859276567b8715465b81aa46783f9678552b4be1e33` |
| shipping | `52faa95369c623e23dfd9e0e10e9e68e3cf53985e7ff6de382452511f1abad56` |

Ce sont des builds propres à ce worktree : aucun n'est une preuve d'un binaire commun avec l'indirect. Les SHA diffèrent d'un dossier de build à l'autre, même à sources égales, parce que les chemins absolus sont inclus.

## Limites et risques restants

- **Coordonnées propres au M4.** Elles sont copiées du tessellateur M4. Sur un autre GPU, elles restent conformes à Vulkan, mais ne coïncident pas forcément bit à bit avec le TES ordinaire de ce GPU. L'égalité PerVertex/ordinaire n'est prouvée que sur M4 Pro.
- **Raccords.** Ils sont prouvés pour des patches de même niveau uniforme, avec un TES dont l'arithmétique est exacte. Un TES arbitraire (NDC, FMA) peut encore produire des fissures : c'est la responsabilité de l'auteur du shader (`precise`/`NoContraction`), comme en Vulkan natif.
- **Slot fragment supplémentaire.** Un pipeline TES PerVertex exige un slot tampon fragment libre de plus (offset implicite 6), même si le fragment ne lit pas PrimitiveId. Sinon, le pipeline est refusé.
- **Invariance entre pipelines.** Le chemin ordinaire garde ses facteurs half : il diverge du chemin PerVertex (et de Vulkan) pour `nextafter(1,+∞)`.
- **Niveaux.** Seuls les niveaux uniformes 1 à 3 sont admis. Tout autre niveau perd le périphérique après VS/TCS.
- **Dessins partiels, chemin ordinaire.** MoltenVK ordinaire arrondit le nombre de patches vers le haut et exécute un TCS sur un patch incomplet. Il ne rend rien ici, parce que le niveau lu vaut 0 : c'est un comportement préexistant, hors de cette branche.
- **Non testés.** Deux dessins TES PerVertex dans une même passe ; soumissions répétées ; sommet provoquant des sorties `flat`.
- **Portée matérielle.** Un seul M4 Pro (macOS 27.2, Xcode 27.1).
- **Préexistants.** Le point mode ordinaire échoue déjà dans MoltenVK. `multiview-scratch` et `multiview-draw` échouent déjà sur `d608d84c`. La référence SPIRV-Cross `load-clip-cull.msl2.tese` échoue déjà sur `bfbde51d`.

## Conflits probables avec l'intégration

- **Branche indirecte `b5a1caec`.** Mêmes fichiers qu'avant, plus :
  - la disposition du plan TES : table PrimitiveID après les offsets, `mvkPerVertexTessPlanSize` ;
  - le 6ᵉ mot de paramètres du générateur ;
  - le slot fragment implicite 6.
- **SPIRV-Cross.** L'API `MSLPerVertexInputBinding` a un quatrième champ. Les initialisations agrégées à trois valeurs restent valides.
- **Maximum de triangles par patch.** `mvkPerVertexTessPlanSize` (`MVKCmdDraw.h`) code en dur 13 triangles par patch, alors que `MVKCommandBuffer.mm` a `kMVKPerVertexTessMaxRecordsPerPatch = 39` (3 × 13). Toute extension des niveaux doit mettre à jour les deux valeurs, ou dériver l'une de l'autre.
- **Cereal.** Le padding attendu de `SPIRVToMSLConversionConfiguration` passe à 158 (`MVKPipeline.mm`). Toute autre modification de cette structure devra réajuster cette valeur.

## Éléments proposés pour `PLAN-PERVERTEX-UPSTREAM.md` (non modifié)

- Jalon TES : trois défauts de revue corrigés (PrimitiveID fragment, invariance des coordonnées, VS des dessins partiels). Matrice 72/72 sur MoltenVK `c3c42e31` et SPIRV-Cross `8de80104`.
- Nouvelle dépendance SPIRV-Cross à proposer en amont avec le reste du WIP TES : `primitive_id_buffer_index`.
- Tâche ouverte : coordonnées de niveaux supérieurs à dériver du matériel avec la même capture SSBO, avant tout élargissement.

## Plus petits pas suivants

1. **Invariance ordinaire.** TCS ordinaire en float32, puis conversion `ceil(clamp)` vers le tampon half. Rejouer ensuite `nextafter`.
2. **Niveaux 4 et plus.** Capturer topologie et coordonnées matérielles (SSBO TES ordinaire, déjà en place) pour les niveaux 4 à 8 et les combinaisons non uniformes. Les générer, puis élargir la classification.
3. **Descripteurs TCS/TES.** Rendre l'ABI float32 compatible avec les argument buffers.

## Reproduction

Depuis `MoltenVK-tes-topology/` (liens `External/` : `SPIRV-Cross` → `../../SPIRV-Cross-tes-topology`, les autres → `../../MoltenVK/External/*`) :

```bash
bash MoltenVK/Tests/run-pervertex-tes-tests.sh build/tes-topology/final-c
bash build/tes-topology/run-ordinary-oracles.sh build/tes-topology/final-c/shipping/build/moltenvk/MoltenVK/libMoltenVK.1.4.3.dylib build/tes-topology/ordinary-oracles-c
bash build/tes-topology/run-defect-cases.sh build/tes-topology/final/dev/build/moltenvk/MoltenVK build/tes-topology/defects-before f1:ccw f2:ccw f3:ccw mixed:ccw mixed:cw seam1:ccw seam2:ccw seam3:ccw seam3:cw vertices1:ccw vertices2:ccw vertices4:ccw vertices5:ccw
```

La troisième commande rejoue l'état « avant » : tests compilés depuis le worktree courant, contre l'ancienne bibliothèque dev `a56eaad6`. Depuis `5a385cee`, le seul changement côté tests est la correction du culling (`3b76c037`), qui ne touche aucun de ces 13 scénarios. `defects-before/PROVENANCE.txt` reste l'enregistrement de référence. Pour l'état « après », passer `build/tes-topology/final-c/dev/build/moltenvk/MoltenVK`.

Côté SPIRV-Cross, depuis `SPIRV-Cross-tes-topology/`, avec le build CTest existant :

```bash
bash tests-other/msl_tese_compute.sh ../MoltenVK-tes-topology/build/tes-topology/spirv-cross-ctest ../MoltenVK-tes-topology/build/tes-topology/spirv-cross-tese-compute-primitive
```
