# PerVertexKHR : audit du contrat public et première tranche upstream (30 septembre 2026)

Audit sans nouveau runtime ni essai GPU. Code examiné à `ec8d70b2` (runtime de `fb3970cc`). TES, soumission et perte de device restent gelés. Le support générique de `VK_KHR_fragment_shader_barycentric` n'est **pas** acquis ; cet audit dit ce qui l'empêche.

**Sources normatives.**
- Spécification Vulkan : `vulkan-docs` embarqué par la CTS 1.4.6.2 (`f6a2970`, 6 août 2026).
- `validusage.json` et `vk.xml` de `External/Vulkan-Headers`.

## 1. Ce qui rend une restriction légale

- **Aucune dérogation propre à l'extension.** La feature `fragmentShaderBarycentric` et la propriété `triStripVertexOrderIndependentOfProvokingVertex` sont les seuls réglages de l'extension (`features.adoc`, `limits.adoc`). La feature active `BaryCoordKHR`, `BaryCoordNoPerspKHR` et la décoration `PerVertexKHR`, sans sous-ensemble d'usages.
- **Aucun code de refus pour un usage valide.**
  - `vkCreateGraphicsPipelines` n'admet que `VK_ERROR_OUT_OF_HOST_MEMORY`, `VK_ERROR_OUT_OF_DEVICE_MEMORY`, `VK_ERROR_INVALID_SHADER_NV`, `VK_ERROR_UNKNOWN` et `VK_ERROR_VALIDATION_FAILED`, plus le succès `VK_PIPELINE_COMPILE_REQUIRED` (`vk.xml`).
  - `vkEndCommandBuffer` n'admet pas non plus `VK_ERROR_FEATURE_NOT_PRESENT`.
  - Un refus d'usage valide par ce code est donc hors norme dès que la feature est exposée.
- **Mécanismes légaux disponibles :**
  - ne pas exposer une feature ou une extension, globalement ou selon l'appareil ;
  - les features restrictives de `VK_KHR_portability_subset` (voir « Capacités exposées ») ;
  - des limites plus basses, qui valent pour tout l'appareil ;
  - les valeurs que la spécification déclare indéfinies ;
  - les codes d'épuisement mémoire, pour un vrai manque de mémoire.
- **Convention de MoltenVK.** Son README demande de signaler par une erreur un écart à la spécification que Metal ne permet pas de combler. C'est une convention du projet, pas un mécanisme légal au sens de Vulkan.

**Capacités exposées qui croisent PerVertexKHR** (`MVKDevice.mm`). Elles valent pour les deux configurations par défaut : la distribution Xcode, et CMake, dont `MVK_USE_METAL_PRIVATE_API` vaut `OFF`. Les bibliothèques de test (`build-library.sh`) ont cette même configuration, avec l'adaptateur de test en plus.
- `tessellationShader`, `multiview` (32 vues), `fillModeNonSolid`, `sampleRateShading`, `multiDraw`, `indexTypeUint8`, `storageInputOutput16`, `shaderInt64` ;
- `extendedDynamicState` et `extendedDynamicState2` ; `extendedDynamicState3PolygonMode` ;
- `vertexAttributeInstanceRateZeroDivisor` ;
- une mémoire paresseuse (`_lazilyAllocatedMemoryTypes`).

**Non exposées :**
- `geometryShader` et `shaderFloat64` ;
- `VK_EXT_mesh_shader` (adaptateur de test seulement) ;
- `provokingVertexLast` et `extendedDynamicState3ProvokingVertexMode` sans l'API privée Metal, désactivée par défaut (`MVK_USE_METAL_PRIVATE_API 0`).

**Portabilité :** `pointPolygons`, `tessellationIsolines` et `tessellationPointMode` valent `false`. `dynamicPrimitiveTopologyUnrestricted` vaut `false`.

## 2. Matrice des restrictions

Classes :
- **N** : règle Vulkan normative. L'usage est invalide, ou son résultat indéfini.
- **C** : capacité non exposée ; la restriction est légale tant que la capacité reste fermée.
- **L** : limitation légale existante (code de retour, limite, propriété, portabilité).
- **B** : blocage d'exposition. Un usage valide est refusé, ou rendu faux.
- **?** : inconnue.

| # | Famille | Comportement actuel | Référence | Classe | Pour lever ou légaliser |
| --- | --- | --- | --- | --- | --- |
| 1 | Extension entière | Fermée partout (`MVKDevice.mm`, garde publique) | features-fragmentShaderBarycentric | C | Choix d'exposition (section 5) |
| 2 | Appareils sans MSL 2.4 | Refus à la création du pipeline | — | C (à faire) | N'exposer l'extension que sur les appareils capables (`8081becf` en pose le principe) |
| 3 | Chemin natif Apple10 | Pris sur Apple10, MSL 4 et triangles, sans `BaryCoord` | — | Choix interne, non prouvé | Le désactiver, ou le prouver (aucun matériel) |
| 4 | Étage géométrie | Refusé (étages VS/FS seulement) | `geometryShader` non exposé | N | — |
| 5 | Adjacence, topologie statique | Refusée (CTS : 792 cas d'adjacence refusés, dont 96 en topologie dynamique) | VUID-VkPipelineInputAssemblyStateCreateInfo-topology-00429 | N | — ; voir aussi la note CTS (section 3) |
| 6 | Adjacence en valeur dynamique | Refusée à l'enregistrement | Aucune VUID trouvée | ? | Si l'usage est valide, le chemin ordinaire est lui aussi faux (`mvk_datatypes.mm:497`) |
| 7 | Topologie dynamique hors de la classe du pipeline | Non gérée | `dynamicPrimitiveTopologyUnrestricted = false` ; VUID-vkCmdDraw-dynamicPrimitiveTopologyUnrestricted-07500 et équivalents des autres dessins | N | — ; admission dans la classe : `162a23a4` (expérimental ; CTS : 120 cas, dont 8 résultats faux en validé, tous d'offset MSAA) |
| 8 | `polygonMode` POINT | Refusé | VUID-VkPipelineRasterizationStateCreateInfo-pointPolygons-04458 | N (portabilité) | — |
| 9 | `polygonMode` LINE, statique ou dynamique | Refusé | `primsrast-barycentric` : `PerVertexKHR` et `BaryCoord*` **indéfinis** hors `FILL` | B | Admettre le pipeline. Les valeurs barycentriques sont libres ; les autres entrées du fragment et le mode ligne doivent rester justes |
| 10 | Rastérisation désactivée en dynamique | Refusée | `extendedDynamicState2` exposé | B | Admettre ; aucun fragment, les effets du VS restent dus |
| 11 | Sommet provoquant dynamique ou « dernier » | Refus du dynamique ; « dernier » jamais exercé sur GPU. La CTS construit `weights.provoking_last` avec `provokingVertexLast = false` | Tables `primsrast-barycentric-order-table-last-vertex` | C dans les configurations par défaut ; B dans un build avec API privée | Garder ces features fermées sans API privée, ou qualifier « dernier » |
| 12 | Multiview à plus d'une vue ; vues par index de device | Refusés | `multiview` exposé, 32 vues | B ; ? pour l'index de device | Capture et rejeu par vue |
| 13 | Tessellation | Contrat TES restreint, figé à `66f9fd97` ; niveaux anormaux : device perdu (CTS : 36 cas refusés) | `tessellationShader` exposé | B, gelé | Isolines et mode point : N (VUID-RuntimeSpirv-tessellationShader-06326 et -06327). Le reste bloque |
| 14 | Mesh | Adaptateur de test seulement (CTS : 690 cas refusés) | `VK_EXT_mesh_shader` fermé | C | — |
| 15 | Indirect avec liaisons à diviseur nul | Refusé | `vertexAttributeInstanceRateZeroDivisor` exposé | B | Gérer les copies de diviseur nul dans le plan GPU |
| 16 | Indirect sous préremplissage Metal immédiat | Refusé | Réglage MoltenVK non standard | L (réglage) | Ne pas exposer l'extension quand ce réglage est actif |
| 17 | Capture indexée et attachements | Refus : attachements paresseux, résolutions logicielles et certaines résolutions profondeur/stencil, suspension avec résolution, attachements inconnus à l'enregistrement | Usages valides ; mémoire paresseuse exposée | B | Capture qui préserve ces attachements |
| 18 | Emplacements de buffer Metal | Refus « no free … buffer slot » | Limites par étage exposées | B ; L possible | Réserver ces emplacements dans les limites exposées (? : vérifier les limites actuelles) |
| 19 | Budget de varyings du rejeu | Refus au-delà du budget Metal | Le niveau de tableau extérieur de `PerVertexKHR` ne compte pas (`interfaces-iointerfaces-locations`) | B ; L possible | Baisser `maxFragmentInputComponents` et `maxVertexOutputComponents` du coût privé (clé et base), pour tout l'appareil |
| 20 | Formes SPIR-V que la capture ou le rejeu refuse | Erreur de SPIRV-Cross, disposition non exportée, disposition indexée incompatible | 64 bits flottants : N (`shaderFloat64` fermé) | ? | Inventaire des formes valides refusées (entiers 64 bits, matrices, tableaux de tableaux, emplacements ≥ 32…) |
| 21 | Tailles extrêmes | Scratch au-delà du maximum Metal : `OUT_OF_DEVICE_MEMORY`. Identifiants de redémarrage ou diviseur étendu au-delà de uint32 : `FEATURE_NOT_PRESENT`. Plus de `UINT32_MAX` enregistrements indirects : device perdu | Codes mémoire admis | L pour le premier ; B pour les autres (le dernier gelé) | Rendre `OUT_OF_DEVICE_MEMORY` pour les deux cas uint32 |
| 22 | Encodage impossible à la soumission | Device perdu (`d09c56cb`, `e7350a3a`) | `VK_ERROR_DEVICE_LOST` est un code admis, pas un refus d'usage | B, gelé | Volet soumission et perte |
| 23 | `VK_PIPELINE_CREATE_FAIL_ON_PIPELINE_COMPILE_REQUIRED_BIT` | Rend toujours `VK_PIPELINE_COMPILE_REQUIRED` | Code de succès admis | L | — |
| 24 | Propriété `triStripVertexOrderIndependentOfProvokingVertex` | `VK_FALSE`, avec des tables conformes | `limits.adoc` | L | — |
| 25 | MSAA : offset et divergence Metal | Défauts de SPIRV-Cross (générique) et de Metal (FB25000318), hors PerVertexKHR | — | Hors contrat | Candidat SPIRV-Cross isolé ; signalement Apple |

## 3. Inconnues explicites

1. **Adjacence en valeur dynamique** sans `geometryShader` : aucune VUID trouvée dans `f6a2970`. Il faut trancher entre usage valide et oubli de la spécification.
2. **La CTS teste l'adjacence sans `geometryShader`.** `fragment_shading_barycentric` lance 792 cas à adjacence sans vérifier cette feature, alors que la VUID-00429 les rend invalides sur MoltenVK.
   - Le `checkSupport` du test n'en demande que pour ses sous-types géométrie.
   - Aucun contrôle commun n'a été trouvé dans `vkPipelineConstructionUtil.cpp` ni dans `vktTestCase.cpp`.
   - Il faut vérifier la CTS amont, puis signaler si besoin. Tant que ce n'est pas fait, ces cas restent des échecs formels.
3. **Formes SPIR-V valides refusées** (ligne 20) : aucun inventaire exhaustif.
4. **Vues par index de device** : on ne sait pas si l'usage est atteignable avec les groupes de devices de MoltenVK.
5. **Limites exposées** : on ne sait pas si elles laissent déjà la marge des emplacements de buffer privés (ligne 18).
6. **Matériel.** Chemin natif Apple10, iOS, M1 et M2 : aucune preuve pour l'instant. Les essais finaux sont prévus sur M1 et M2 ; aucun M3 n'est disponible, et Intel est annulé.
7. **Conformité de MoltenVK.** Une exposition qui garderait des écarts signalés suit la convention du projet, mais sa compatibilité avec une revendication de conformité n'est pas établie.

## 4. Composants livrables séparément

| Composant | Contenu | Preuves disponibles | Dépendances | Garde |
| --- | --- | --- | --- | --- |
| **K1** : éventails dynamiques du chemin ordinaire | Topologie Vulkan dans l'état de rendu (partie générique de `162a23a4` : `vkPrimitiveTopology`, encodage de `MVKCmdSetPrimitiveTopology`, `getPrimitiveTopology`), puis `fb3970cc` | Oracle ordinaire (rouge avant, vert après, 4 mutations), filet CTS ordinaire de 562 cas identique, cas d'éventail de la CTS barycentrique. `fb3970cc` s'applique proprement sur `upstream/main`, qui a le même défaut | Extraire la plomberie (une dizaine de lignes) ; un oracle qui ne demande pas l'extension barycentrique | Aucune : correctif ordinaire |
| **K2** : groupement multiview | `3e14cb82` : première vue de chaque passe, décalage `1 << 32` indéfini | Test hôte `MultiviewGroupingTests.cpp`. S'applique proprement sur `upstream/main` | Retirer les fichiers de test PerVertex du commit | Aucune |
| **K3** : correctifs ordinaires mêlés au code PerVertex | Stride des diviseurs nuls (`2911d0a1`), débordements de tessellation (`8d650476`, `8f33520d`) | Tests PerVertex seulement | Conflits sur `upstream/main` : à réécrire | Aucune |
| **K4** : SPIRV-Cross | 25 commits d'options MSL opt-in (capture, rejeu, PerVertexKHR portable et natif, TES en compute, mesh) | Tests de référence du fork. Candidat `+ 0.5` à part, gelé | CLA Khronos et déclaration sur l'usage d'IA (CONTRIBUTING de SPIRV-Cross). Suite complète `test_shaders.py` avec les versions fixées, non faite | Options opt-in : aucun effet sans MoltenVK |
| **K5** : cœur PerVertexKHR portable dans MoltenVK | Capture et rejeu directs et indexés, scratch, redémarrage, vue unique | CTS barycentrique validée ; matrices et suites M4 | K4 épinglé ; lignes B de la section 2 | Extension fermée, ou exposée par un réglage explicite |
| **K6** : indirect | Plan GPU, continuation | Matrice 127/127, continuation | Protocole de soumission (gelé) | Fermée |
| **K7** : TES | Contrat restreint | 142/142 | Gelé | Fermée |
| **K8** : mesh | Adaptateur | 41/41 | `VK_EXT_mesh_shader` lui-même fermé | Fermée |
| **K9** : volet perte de device et synchronisation | Commits du volet perte, dont `662c7f98` et `d24159ce` à `a3f02d1c` | Oracles de perte | Gelé | — |

## 5. Première tranche proposée

**Tranche 1 : K1 et K2, deux correctifs ordinaires sans PerVertexKHR.**
- **Utiles seuls.** Ils corrigent des défauts présents dans `upstream/main`, pour tous les utilisateurs de MoltenVK.
- **Petits** (quelques dizaines de lignes) et sans lien avec les volets gelés.
- **Prouvés.** Pour K1 : l'oracle, les mutations et la CTS ordinaire. Pour K2 : un test hôte.
- **Ce qu'ils n'affirment pas :** aucun support de `VK_KHR_fragment_shader_barycentric`, aucune nouvelle admission.

**Préalables avant d'ouvrir la PR :**
1. Extraire la plomberie d'état de K1 en un commit autonome, puis vérifier la compilation sur `upstream/main`.
2. Écrire un oracle d'éventail dynamique qui ne demande pas l'extension barycentrique, puis le passer sur M4.
3. Vérifier les règles de contribution (CLA de MoltenVK) et les en-têtes de copyright.

Les deux premiers sont du runtime et du GPU : hors de cet audit, à faire après accord.

**Suite possible, pour le choix à venir :**
- **Livraison progressive, gardes fermées.** Tranche 2 : K4 (SPIRV-Cross, opt-in). Tranche 3 : K5 derrière une extension fermée, ou un réglage explicite. Aucune annonce de support.
- **Exposition complète.** Il faut lever toutes les lignes B : 9, 10, 12, 15, 17, 18, 19, 21 et la ligne 20 une fois inventoriée. Il faut aussi rouvrir TES et le volet soumission et perte (lignes 13 et 22), et régler l'adjacence (lignes 5 et 6, note CTS).
