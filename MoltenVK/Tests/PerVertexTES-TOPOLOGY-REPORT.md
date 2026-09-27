# Topologie TES PerVertexKHR générée sur GPU : rapport de jalon (M4 Pro, 27 septembre 2026)

Rapport destiné au fil principal, pour revue avant intégration. Rien n'a été poussé ni publié, et aucune PR ou commentaire n'a été créé. Je n'ai touché ni au checkout principal, ni aux worktrees indirects, ni à `/private/tmp/pervertex-integrated-20260927`, ni au plan. La garde publique reste fermée. Ce fichier n'est pas suivi par git.

## Verdict

**Fait :**

- Plus petit jalon atteint sur M4 : topologie TES générée sur GPU à partir des facteurs float32 réellement écrits par le TCS, avec suppression des patches selon Vulkan.
- Périmètre : triangles, `equal_spacing`, `cw` et `ccw`, niveaux uniformes 1, 2 et 3.
- Refus déterministe, à la création du pipeline, de tout autre mode.
- Refus défini sur GPU pour tout autre niveau.
- Matrice 53/53 sous validation Metal API/GPU.
- Huit images d'oracles ordinaires reproduites octet par octet.

**Non fait (hors jalon) :** niveaux non uniformes ou supérieurs à 3, autres domaines, espacements et origines, descripteurs TCS/TES, instances, multiview, indexé/indirect, autres Macs.

## Départ et isolation

| Élément | Valeur |
| --- | --- |
| SHA de départ | MoltenVK `d608d84c507099909d735843e0af4993aac92661` + WIP TES du checkout partagé ; SPIRV-Cross `4308267dfae1dfc13fc94ebbdcaa624ede6396e6` + WIP float32/TES compute |
| Worktrees | `MoltenVK-tes-topology/` et `SPIRV-Cross-tes-topology/`, branche `claude/pervertex-tes-gpu-topology` |
| Import WIP | 28 fichiers MoltenVK et 28 fichiers SPIRV-Cross copiés sans modification. Chaque fichier est haché avant, après et dans la destination : 0 écriture concurrente. Manifestes `build/tes-topology/import/moltenvk-wip.json` (SHA-256 `00638769…fdbc2f8`) et `spirv-cross-wip.json` (`3ad86b8a…ac00e0`) |
| SPIRV-Cross | `bfbde51dfc2fec3a70f6c544144efae0f105c326` : import du WIP, **commit local non public**. Le pin MoltenVK pointe vers lui |

**Commits MoltenVK** (base `d608d84c`) :

| SHA | Contenu |
| --- | --- |
| `b093f6e1` | import du pilote TES WIP et pin SPIRV-Cross |
| `daa44403` | générateur GPU, TCS/TES float32, admission par modes, statut en fin de soumission |
| `a77a4fa6` | fuite d'options float32 entre étages corrigée, tests Vulkan |
| `65a407ca`, `c3baa332`, `3c395efe`, `a2b81fff` | ajustements du runner et des tests |
| `3da96b99` | README du test ; matrice finale exécutée sur ce SHA |
| `c825c46c` | test hôte de préparation des helpers |

## Contraintes vérifiées avant d'écrire

- **Ordre des coins.** Pour la tessellation sans géométrie, Vulkan laisse l'ordre des coins PerVertexKHR à l'implémentation, mais impose sa cohérence avec `BaryCoordKHR` (spécification `primsrast.adoc`). L'ordre des triangles et des sommets du tessellateur est lui aussi laissé à l'implémentation (`tessellation.adoc`).
- **Enroulement.** Avec l'origine haut-gauche, `ccw` exige une aire signée négative dans l'espace (u,v). Les motifs hérités du pilote sont orientés positivement, donc horaires au sens Vulkan. Le générateur inverse les coins 1 et 2 pour `ccw`.
- **Suppression et arrondi.** Un patch est supprimé si un outer pertinent est ≤ 0 ou NaN. `equal_spacing` clamp dans `[1, maxLevel]` puis arrondit vers le haut. Le TES est invoqué *au moins une fois* par sommet unique (`shaders.adoc`), ce qui légitime la capture par coin.
- **ABI float32.** SPIRV-Cross refuse `tessellation_factors_float32` dès que `argument_buffers` est vrai. MoltenVK l'active par défaut (`MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=1`). D'où le périmètre TCS/TES sans descripteurs, et les facteurs alimentés par attribut de sommet dans les tests.
- **Barrières Metal.** La restriction de barrière fragment→vertex sur Apple3-10 n'intervient pas ici : chaque étape compute se termine avant le redémarrage de la passe de rendu.

## Implémentation

L'admission reste de test : `MVK_TEST_TES_PERVERTEX_ADMISSION`, jamais défini par les builds shipping. Elle remplace la correspondance SPIR-V exacte du pilote par des modes réfléchis :

- triangles, `equal_spacing`, `cw` ou `ccw`, sans point mode, 3 points de contrôle, origine haut-gauche ;
- TCS/TES sans descripteurs, attributs de sommet sans diviseur ;
- sans cache, sans spécialisation, une vue, un échantillon.

Déroulement d'un dessin :

1. **TCS.** VS et TCS s'exécutent en compute, le TCS en float32 (`spvTessellationFactorsFloat`, 24 o/patch, vérifié dans le MSL généré). Les options float32 et argument buffers sont restaurées pour les étages suivants.
2. **Générateur.** `perVertexTessTopology` s'exécute en trois phases :
   - classification par patch : décodage des bits, sûr en fast-math pour NaN et signe ;
   - préfixe sériel (`ponytail:` noté, plafond pour de très grands nombres de patches) ;
   - émission des enregistrements par coin, avec les motifs 1/6/13 triangles prouvés par les oracles.
3. **Capture et replay.** TES compute sur `39 × patches` threads gardés, puis replay indirect sur le compte écrit par le GPU.
4. **Refus GPU.** Un niveau hors motif prouvé ne capture ni ne rejoue rien. `finish()` lit le statut avant les fences et déclare `VK_ERROR_DEVICE_LOST`. VS et TCS de ce dessin ont déjà tourné.
5. **Capacité.** Réservation transactionnelle avant soumission : 11 allocations, dont 24 o/patch pour les niveaux et le plan, bornée au maximum prouvé.

## Preuves

**`build/tes-topology/final/`** — 53/53 cas sur `3da96b99`, `EVIDENCE.sha256` 228/228, `SOURCE-INDEX.txt`, dumps MSL :

| Groupe | Cas |
| --- | --- |
| Topologie, `ccw` et `cw` | facteurs 1, 2, 3 ; `nextafter(1,+∞)` ; patch supprimé par zéro puis par NaN, entre deux patches de niveaux 2 et 3 ; fractions 1.5 / 2.9 / 0.25 ; culling avec patch miroir |
| Prefill | modes 1 et 2 |
| Refus GPU → `DEVICE_LOST`, 0 pixel, écriture antérieure préservée | niveau 4, niveaux non uniformes, inner NaN |
| Refus à la création du pipeline, le pipeline ordinaire restant disponible | quads, `fractional_odd`, point mode, origine bas-gauche, TCS avec UBO, cache |
| Refus à l'enregistrement | `firstVertex`, instances |
| Autres builds | build sans admission (-8), build shipping (extension fermée, pas d'adaptateur) |
| Garanties du pilote conservées | 15 cas : ordered/swapped/wrong-patch/control, gardes après bind compute, cache, patch size, spécialisation, instance, first, indexé, public |

**Oracles par scénario.**

- **Pipeline ordinaire.** Couverture et valeurs TES non linéaires interpolées identiques au pipeline TES ordinaire matériel, écart maximal 1/255.
- **Cohérence barycentrique.** Vérifiée sur chaque pixel couvert.
- **Modèle CPU.** Chaque triangle est échantillonné contre un modèle CPU indépendant des coins ordonnés : 2, 12, 26 et 19 triangles selon les cas.
- **Contrôle négatif.** Le fragment aux coins permutés échoue, avec 4 à 60 écarts de canal.
- **`nextafter`.** L'image PerVertex est identique octet par octet à celle de 2.0, tandis que le chemin ordinaire reste identique au niveau 1.

**Mutations du générateur, reconstruites depuis `HEAD` (`mutation.diff`), toutes détectées :**

| Mutation | Détection |
| --- | --- |
| Enroulement inversé | 4 704 pixels de couverture différents sous culling ; modèle CPU en échec |
| Intérieur du niveau 3 à 1/4 | 958 pixels de valeurs différentes |
| Offsets de patch ignorés | 710 pixels de couverture différents |

L'inversion d'enroulement seule passe la comparaison sans culling. Seuls le culling et le modèle CPU la voient.

**`build/tes-topology/ordinary-oracles/`** (`run-ordinary-oracles.sh`, `EVIDENCE.sha256` 38/38) :

- bibliothèque shipping `5acd9781…`, précision 4/4, facteur 3 (natif, dx, dy) 3/3, facteur 2 1/1, identiques aux images stockées ;
- les reproducteurs facteurs 2/3 sont des copies modifiées seulement pour ne plus exiger l'extension barycentrique, fermée en shipping (`main-ordinary.diff`).

**Tests hôte** (`build/tes-topology/host/`) :

- scratch TES : 11 allocations transactionnelles ;
- helper-preflight avec cas TES ;
- scratch, draw-size, restart, prefill, topology, memoryless, indirect CPU, Cereal et convertisseur ;
- SPIRV-Cross `bfbde51d` : 11/11 CTests ciblés.

**Défaut préexistant, non causé par cette branche :** `multiview-scratch` et `multiview-draw` échouent déjà sur `d608d84c`.

**Bibliothèques** (Debug arm64, `PROVENANCE.txt`) :

| Build | SHA-256 |
| --- | --- |
| dev | `eb81d38e383b569d5cf1b92ef8dadc989b3679f2c5a599f1990d2e0cf26b8f18` |
| sans admission | `a381eb5b63ed83fd05c6ad11ac77158c14629445e3de1ed3ad39220f3aea53a6` |
| shipping | `5acd97812a09dae17c554ec1bd9a1d4a50db3badacf6b412a5ae06ee83d1a34e` |

Ce sont des builds propres à ce worktree : aucun n'est une preuve d'un binaire commun avec l'indirect.

## Limites et risques

- **Invariance entre pipelines.** Le chemin ordinaire garde ses facteurs half : il **diverge** du chemin PerVertex (et de Vulkan) pour les niveaux que half ne représente pas, comme `nextafter`. La correction ordinaire (TCS float32 puis conversion `ceil` vers un tampon half séparé) n'est pas faite.
- **Niveaux admis.** Seuls les niveaux uniformes 1 à 3 sont admis. Tout autre niveau perd le périphérique après exécution de VS/TCS : c'est un résultat défini, mais brutal.
- **Sommet provoquant.** La correspondance, entre replay et matériel, du sommet provoquant des sorties TES `flat` n'est pas vérifiée. Aucun ordre n'est imposé par Vulkan pour la tessellation.
- **Ordre des primitives.** L'ordre des triangles d'un même patch est défini par l'implémentation. L'ordre entre patches est préservé.
- **Portée matérielle.** Un seul M4 Pro (macOS 27.2, Xcode 27.1). Les motifs Metal ne sont pas prouvés sur M1/M3.
- **Pipeline ordinaire en point mode.** Il échoue déjà dans MoltenVK (point size avec une topologie triangle), indépendamment de cette branche.

## Conflits probables avec l'intégration en cours

- **Branche indirecte `b5a1caec` / espace intégré.** Mêmes fichiers touchés :
  - `MVKPerVertexScratch.h` : l'indirect utilise `buffers[7]` comme plan, ici `buffers[7..12]` servent au TES ; **renumérotation obligatoire** ;
  - `MVKCmdDraw.mm`, `MVKCommandBuffer.*` ;
  - `MVKCommandEncodingPool.*`, `MVKCommandResourceFactory.*` et le source MSL d'aide : deux noyaux ajoutés en fin de chaîne ;
  - `MVKQueue.*` : deux contrôles de statut dans `finish()` à fusionner ;
  - `PerVertexHelperPreflightTests.mm` et son script : les deux branches utilisent le créateur n°3.
- **Pilote TES de l'espace intégré.** Ce jalon remplace :
  - la macro `MVK_TEST_TES_PERVERTEX_FIXTURE` et `fixture.h` par `MVK_TEST_TES_PERVERTEX_ADMISSION` ;
  - les tables CPU par le générateur ;
  - `run-pervertex-tes-tests.sh` ;
  - deux modes obsolètes de `main.cpp` (`reject-factor`, `reject-count`).
- **Checkout partagé.** Il continue d'évoluer. Ce travail se fonde sur l'instantané haché de 14:45.

## Plus petits pas suivants

1. **Invariance.** Compiler aussi le TCS ordinaire en float32, avec un noyau qui écrit `ceil(clamp)` vers le tampon half matériel pour `equal_spacing`. Puis rejouer `nextafter` : ordinaire et PerVertex doivent coïncider.
2. **Niveaux 4 et plus, et combinaisons non uniformes.** Dériver l'algorithme de triangulation Metal et le valider automatiquement contre des images ordinaires (niveaux 4 à 8, combinaisons outer/inner), avant d'élargir la classification.
3. **Descripteurs TCS/TES.** Rendre l'ABI float32 compatible avec les argument buffers dans SPIRV-Cross.

## Reproduction

Depuis `MoltenVK-tes-topology/`, `External/` lié :

```bash
bash MoltenVK/Tests/run-pervertex-tes-tests.sh build/tes-topology/final
bash build/tes-topology/run-ordinary-oracles.sh build/tes-topology/final/shipping/build/moltenvk/MoltenVK/libMoltenVK.1.4.3.dylib build/tes-topology/ordinary-oracles
```

Liens `External/` :

- `SPIRV-Tools`, `Volk`, `Vulkan-Headers`, `Vulkan-Tools` et `cereal` → `../../MoltenVK/External/*` ;
- `SPIRV-Cross` → `../../SPIRV-Cross-tes-topology`.
