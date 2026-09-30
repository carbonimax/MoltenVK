# K4 : série SPIRV-Cross pour le chemin portable VS/FS, dossier préparatoire (30 septembre 2026)

Dossier en lecture seule demandé par Astra après la publication de K1 (#2851) et K2 (#2852) : délimiter la série
SPIRV-Cross nécessaire au chemin portable PerVertexKHR vertex/fragment, séparer TES, mesh, Apple10 et le candidat
`+ 0.5`, définir le protocole de tests avec les outils épinglés, et vérifier les exigences de contribution. **Rien n'est
extrait ni compilé** : aucune branche, aucun worktree, aucun commit dans SPIRV-Cross. Les gels TES, soumission et perte
restent en vigueur ; K3 viendra ensuite.

## 1. Base

- Le fork SPIRV-Cross (`SPIRV-Cross-pervertex-generic`, branche `claude/pervertex-generic`, pointe `6af5a67f`, épinglé
  par le fork MoltenVK) contient 88 commits au-dessus de `6c09849f`, le pin de MoltenVK `a63d4863`. Parmi eux, **63
  commits upstream** mènent à `aa217aeb`, puis viennent **25 commits du fork**, tous de `Jean-Philippe
  <github@meunier.jp>`.
- `aa217aeb` est à la fois la base de fusion du fork, le pin SPIRV-Cross de MoltenVK `upstream/main` (`52aa21f5`) et la
  tête de `KhronosGroup/SPIRV-Cross` `main` (`git ls-remote` du 30 septembre). **Aucune dérive** : la série se pose
  directement sur la branche cible.
- Le clone principal `SPIRV-Cross` (branche `codex/pervertex-khr-msl` à `4308267d`) porte des modifications non
  commitées du 27 septembre (5 fichiers, +398/−41), vraisemblablement le TES importé depuis dans `bfbde51d`. Il n'a pas
  été touché et ne doit pas servir à l'extraction.

## 2. Inventaire des 25 commits

Groupes : **N** natif Apple10, **P** portable VS/FS, **MV** multiview, **T** TES, **M** mesh. « Fixup » : commit à fondre
dans son commit d'origine à l'extraction.

| Commit | Titre (abrégé) | Groupe | Options et API ajoutées | Tests | Série VS/FS |
|---|---|---|---|---|---|
| `beb6978e` | opt-in native PerVertexKHR fragment inputs | N | `supports_per_vertex_fragment_input` (MSL 4.0, `vertex_value`, Apple10), option CLI | `shaders-msl/frag` + `reference/` (3) | décision §4 |
| `170926b8` | opt-in captured PerVertexKHR input buffers | P | `set_msl_per_vertex_input_buffer`, `MSLCapturedVertexLayout`, `MSLPerVertexInputBinding` | `tests-other` | oui |
| `bcc63e30` | export captured vertex layout including builtins | P | `get_msl_captured_vertex_layout`, `MSLCapturedVertexBuiltin` | `tests-other` | oui |
| `ee93578f` | compile captured vertex output replay | P | `compile_captured_output_replay`, `MSLCapturedOutputReplayBinding` | `tests-other` | oui |
| `30b59910` | reversed-depth viewport emulation in captured replay | P | (option upstream `emulate_reversed_depth_viewport` dans le rejeu) | `tests-other` | oui |
| `75f8212a` | reconstruct portable PerVertexKHR composite inputs | P | composites depuis le tampon | `tests-other` | oui |
| `b4358daa` | preserve explicit locations in composite interfaces | P | — | `tests-other` | oui |
| `66ad847b` | opt-in portable barycentric fragment inputs | P | `set_msl_fragment_barycentric_input`, `MSLFragmentBarycentricInputBinding` | `tests-other` | oui |
| `079a5865` | portable barycentric basis in captured replay | P | `MSLCapturedOutputReplayBarycentricBinding` | `tests-other` | oui |
| `4a5436c7` | preserve composite captured output interfaces | P | — | `tests-other` | oui |
| `932ad828` | mixed barycentric builtins, copied interpolation pointers | P | — | `tests-other` | oui |
| `95a5ef19` | typed composite PerVertex capture and replay | P | — (tests) | `tests-other` | oui |
| `5bf560a9` | barycentric input aliases and mixed builtins | P | — | `tests-other` | oui |
| `5d2f545d` | select captured vertex outputs for raster replay | P | sélection des sorties | `tests-other` | oui |
| `65743e78` | contributor license headers on new shader tests | P/N (fixup) | — | en-têtes de 43 fichiers, dont les tests natifs | oui, fondu |
| `6af5a67f` | ignore builtin input mappings in portable Location checks | P | — | `tests-other` | oui |
| `4308267d` | captured multiview layer replay | MV | `MSLCapturedOutputReplayBinding::multiview_layer` | `tests-other` | non (K5 = vue unique) |
| `bfbde51d` | **« Import TES compute capture and float32 TessLevel WIP »** | T | `tese_as_compute`, `tessellation_factors_float32`, CLI | `tests-other`, dont `.mm` Metal | non (gel TES) |
| `8de80104` | fragment PrimitiveId from a per-triplet table | T | `primitive_id_buffer_index` (MoltenVK ne l'emploie qu'avec TES) | `tests-other` | non |
| `68720b61` | float32 tessellation factors with argument buffers | T | `get_tessellation_factors_float32_incompatibility` | `tests-other` | non |
| `e88eb7ec` | preserve flattened TES builtin member access | T (fixup) | — | — | non |
| `8cd36d69` | LocalSizeId workgroup size of mesh shaders | M | — (correctif mesh générique) | `shaders-msl/mesh` + `reference/` | non ; candidat indépendant |
| `4260ab77` | fragment PerVertexKHR from mesh primitive corners | M | `mesh_per_vertex_corner_locations`, CLI | `shaders-msl` + `tests-other` | non (K8 fermé) |
| `bf06eece` | merge : mesh corners avec float32 tessellation | M/T | — (fusion sans contenu propre) | — | non |
| `1ab7e84b` | license header on mesh LocalSizeId fixture | M (fixup) | — | — | non |

Volumes (lignes ajoutées ; bibliothèque, CLI et CMake / tests) : N 102 / 838 ; P 1 457 / 4 841 ; MV 41 / 400 ;
T 487 / 1 756 ; M 140 / 1 005.

**Candidat `+ 0.5`.** Il ne fait pas partie des 25. Le décalage `+ 0.4375` de `interpolate_at_offset`
(`spirv_msl.cpp:13535-13539` à `6af5a67f`) est déjà présent à `aa217aeb` ; la série le laisse tel quel. Le candidat reste dans son
clone isolé (tag `candidate-frozen-until-intel` sur `6e51dee7`).

## 3. Essai textuel de la série

Méthode : `build/astra/k4-dossier/k4-dry-run.sh`, clone nu `--shared` dans un dossier temporaire, application des
groupes par `git merge-tree --write-tree` et `git commit-tree`. Aucune branche, aucun worktree, aucun fichier créé dans
un dépôt ; **rien n'est compilé**. Journal : `k4-dry-run.log`.

| Essai | Résultat |
|---|---|
| `170926b8` (premier portable) sans `beb6978e` | conflit : `spirv_msl.cpp` (1 hunk), `spirv_msl.hpp` (2 hunks) |
| `beb6978e` seul sur `aa217aeb` | s'applique |
| **Série A** : `beb6978e` + les 15 commits P, dans l'ordre du fork | **16/16 s'appliquent**, arbre `71924ba7` |
| `4308267d` (MV) sur A | s'applique |
| TES (4) sur A, sans MV | s'applique |
| `8cd36d69` seul sur `aa217aeb` | s'applique |
| mesh (3) sur A | s'applique |
| A + MV + TES + mesh dans l'ordre du fork | arbre `051ffe0a`, **identique** à la pointe du fork |
| fusion `bf06eece` | arbre enregistré = fusion automatique : aucun contenu propre |

Seule dépendance textuelle établie hors série : `170926b8` → `beb6978e`. Elle tient en trois endroits : l'aiguillage
de la décoration PerVertexKHR (chemin tampon, sinon natif), la déclaration de `supports_per_vertex_fragment_input` et
des membres privés voisins. Aucun commit portable postérieur n'utilise les fonctions natives.

## 4. Apple10 : décision demandée

`beb6978e` émet les entrées natives `vertex_value` (MSL 4.0, GPU Apple10). Aucun GPU Apple10 n'est disponible : cette
voie n'a qu'une preuve de compilation, et MoltenVK note qu'elle n'a jamais rendu à travers Vulkan.

1. **(recommandé) Réécrire `170926b8` pour qu'il tienne seul** : trois hunks ; sans tampon configuré, la décoration
   PerVertexKHR continue de lever l'erreur d'upstream. La série VS/FS ne contient alors aucun code Apple10. `beb6978e`
   devient une proposition indépendante et facultative (option CLI et tests de référence dans le style upstream), dont
   la fusion avec la série se résout dans le même aiguillage.
2. Garder `beb6978e` en tête de la série : aucune réécriture, mais la série embarque une voie Apple10 non éprouvée sur
   GPU.

## 5. Conséquences pour K5 (à consigner, pas à traiter maintenant)

Le runtime du fork MoltenVK référence des API exclues de la série : `multiview_layer` (`MVKPipeline.mm:1579-1581`),
`primitive_id_buffer_index` (`MVKCmdDraw.mm:473`, `MVKPipeline.mm:1463`, TES), `supports_per_vertex_fragment_input`
(`MVKPipeline.mm:2190`, cache `3406`), `tese_as_compute` et `tessellation_factors_float32`,
`mesh_per_vertex_corner_locations`. K5 devra être réduit à la vue unique sans TES ni mesh, et sans natif si l'option 1
est retenue, avant de pouvoir se construire sur la série.

## 6. Options désactivées par défaut

`spirv_msl.hpp` à `6af5a67f` : `supports_per_vertex_fragment_input = false` (l. 420), `multiview_layer = false`
(l. 126), `tessellation_factors_float32 = false` (l. 522), `tese_as_compute = false` (l. 536),
`mesh_per_vertex_corner_locations = 0` (l. 409), `captured_output_replay = false` (l. 1225),
`fragment_barycentric_input_enabled = false` (l. 1231) ; les index de liaison valent `~0u`. Le tampon PerVertex, le rejeu
et les barycentriques portables ne s'activent que par appel explicite de l'API (`set_msl_per_vertex_input_buffer`,
`compile_captured_output_replay`, `set_msl_fragment_barycentric_input`).

Aucun fichier existant de `reference/`, `shaders/` ou `shaders-msl*/` n'est modifié par les 25 commits (seulement des
ajouts : 3 tests natifs, 3 tests mesh). La preuve d'innocuité reste à produire : suite complète sans aucun écart
(§8, étapes 2 et 3).

## 7. Exigences de contribution SPIRV-Cross

| Exigence | Source | État |
|---|---|---|
| CLA Khronos pour SPIRV-Cross | `CONTRIBUTING.md` | À signer par l'utilisateur à la première PR (distinct du CLA MoltenVK). |
| Déclaration sur l'usage d'IA | `CONTRIBUTING.md` | L'utilisateur la fait en soumettant. 6 commits sur 25 portent un trailer `Co-Authored-By: Claude` (`bfbde51d`, `8de80104`, `68720b61`, `8cd36d69`, `4260ab77`, `6af5a67f`) : harmoniser à l'extraction, sur décision de l'utilisateur. |
| En-tête Apache 2.0 sur les nouveaux fichiers | README, *Licensing* | Présent sur les tests (après fondu de `65743e78`). |
| Formatage `clang-format` (`.clang-format`, `format_all.sh`) | README, *Formatting* | Jamais passé sur le code du fork : vérifier les hunks de la série à l'extraction. |
| Nouveau test et référence pour toute fonctionnalité | README, *Testing* | Natif et mesh : oui (`shaders-msl` + `reference`). Portable : **aucun**, faute d'accès CLI (risque 1). |
| Suite sans écart (`test_shaders.sh`), CI verte | README | Non fait (§8). |
| CI upstream | `.github/workflows/main.yml` | Windows, Ubuntu 24.04 et 22.04, macOS 15 ; `-DSPIRV_CROSS_WERROR=ON -DSPIRV_CROSS_MISC_WARNINGS=ON -DSPIRV_CROSS_SHARED=ON`, puis `ctest`. Le fork n'a été construit qu'avec Apple clang via MoltenVK : GCC et MSVC inconnus. |

Câblage CMake : les tests du fork sont dans le bloc `if (PYTHONINTERP_FOUND AND SPIRV_CROSS_ENABLE_TESTS)`, comme ceux
d'upstream. `SPIRV_CROSS_ENABLE_TESTS` passe à `OFF` si glslang ou SPIRV-Tools manquent sous `external/`
(`NO_DEFAULT_PATH`) : les commandes de construction qui les appellent sont donc protégées, et utilisent les versions
épinglées. Les scripts `tests-other/*.sh` du portable (compilation Metal) ne sont pas dans `ctest` : complément macOS.

**Risques d'acceptation, à soumettre tôt au mainteneur :**
1. L'API portable passe par des structures et n'a pas de surface CLI, donc pas de test `shaders-msl` + `reference/`.
   Précédents upstream de harnais API dans `ctest` : `tests-other/msl_resource_bindings.cpp`,
   `tests-other/msl_constexpr_test.cpp`. Le mainteneur peut néanmoins demander des options CLI.
2. L'API C (`spirv_cross_c`) n'est pas étendue ; upstream l'étend au cas par cas.
3. Taille : environ 1 460 lignes de bibliothèque et 4 800 lignes de tests pour le portable.

## 8. Protocole de tests (avant toute PR)

| Étape | Action | Vert si | Accord requis |
|---|---|---|---|
| 0 | Extraction : worktree neuf depuis `aa217aeb`, série A ou série réécrite (§4), fixups fondus | chaque commit s'applique | feu vert d'Astra |
| 1 | `./checkout_glslang_spirv_tools.sh` (glslang `31b9aacf`, SPIRV-Tools `ef96ed76`, SPIRV-Headers `04fd3caa`) puis `./build_glslang_spirv_tools.sh Release` | outils construits sous `external/` | **oui** (clonage réseau des dépôts Khronos) |
| 2 | Référence `aa217aeb` : CMake avec les options de la CI, `ctest`, `./test_shaders.sh` | vert, ou échecs préexistants consignés | — |
| 3 | Pointe de la série : mêmes commandes | `ctest` vert, nouveaux tests compris ; `test_shaders.sh` sans écart sur l'existant | — |
| 4 | `./update_test_shaders.sh` sur la pointe | seuls des ajouts attendus (aucun pour le portable seul) | — |
| 5 | Chaque commit de la série : construction et `ctest` | vert à chaque étape (bissectable) | — |
| 6 | `clang-format --dry-run` sur les hunks de `spirv_msl.{cpp,hpp}` et `main.cpp` | aucune correction | — |
| 7 | macOS : scripts `tests-other/msl_{barycentric_portable,capture_replay,capture_composites}.sh` | MSL généré compilé par `xcrun metal` | — |
| 8 | Matrice Windows/Ubuntu/macOS : la série poussée sur un fork SPIRV-Cross de l'utilisateur, Actions activées | CI verte avant PR | **oui** (publication) |

Le lien avec MoltenVK (K5 réduit construit sur la pointe de la série) appartient à K5, pas à K4.

## 9. Découpage proposé pour l'extraction (Astra arbitre)

Garder l'ordre du fork, fondre `65743e78` dans chaque commit d'origine, et couper en préfixes, sans réordonner :

1. **PR K4-a, tampon et rejeu** : `170926b8` (réécrit), `bcc63e30`, `ee93578f`, `30b59910`, `75f8212a`, `b4358daa`.
2. **PR K4-b, barycentriques portables et composites** : `66ad847b`, `079a5865`, `4a5436c7`, `932ad828`, `95a5ef19`,
   `5bf560a9`, `5d2f545d`, `6af5a67f`.
3. Hors série, plus tard et facultatifs : natif `beb6978e` ; correctif mesh générique `8cd36d69`.

## 10. Preuves

`build/astra/k4-dossier/` : `k4-dry-run.sh`, `k4-dry-run.log`, `EVIDENCE-K4.sha256`.
