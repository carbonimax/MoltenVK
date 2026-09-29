# PerVertexKHR : topologie primitive dynamique hors TES (30 septembre 2026)

Portée : pipelines PerVertexKHR portables sans tessellation, avec `VK_DYNAMIC_STATE_PRIMITIVE_TOPOLOGY`. L'adjacence reste refusée. Le contrat TES reste figé à `66f9fd97`, et le volet perte de device reste gelé. La soumission n'est pas touchée. Seul un Apple M4 Pro sous macOS 27.2 est prouvé.

## 1. Commits

| Commit | Contenu |
| --- | --- |
| `a07dcc0b` | Oracle `PerVertexDynamicTopologyTests.mm` et runner `run-pervertex-dynamic-topology-tests.sh` (test seul) |
| `0acbd138` | Forme `adjacency` de l'oracle : un changement dynamique vers une topologie à adjacence doit être refusé |
| `162a23a4` | Correctif runtime : admission de la topologie dynamique |

## 2. L'oracle

- **Pipelines comparés.**
  - Un pipeline statique par topologie de la classe.
  - Un pipeline dynamique, créé avec la première topologie de la classe.
  - Classes : triangles (liste, bande, éventail) et lignes (liste, bande).
- **Dessins.**
  - Directs et indexés : 6 sommets à partir du sommet (ou de l'indice) 4.
  - `firstInstance` 2 ou 3, en alternance.
- **Modes.**
  - 0 : pipelines statiques.
  - 1 : pipeline dynamique, avec un changement de topologie entre chaque dessin.
  - 2 : pipeline dynamique, avec la première topologie gardée.
- **Contrôles.**
  - Couverture non nulle.
  - Mode 1 égal au mode 0 pixel par pixel.
  - Mode 1 différent du mode 2 : le changement doit avoir un effet.
  - Nombre d'invocations VS : 6 par dessin.
- **Fragment.** Il pondère les trois valeurs de sommet dans l'ordre. Il lit `BaryCoordKHR` pour prendre le chemin portable, sans que la valeur lue compte.
  - **Angle mort.** L'oracle ne voit donc pas les poids barycentriques. C'est la CTS qui les contrôle (section 5).

## 3. Rouge avant, vert après, mutation

| Bibliothèque | Résultat |
| --- | --- |
| **Avant** (runtime de `a07dcc0b`, puis de `0acbd138` pour l'adjacence) | Les 5 formes sont refusées à la création : `vkCreateGraphicsPipelines = -8`, « requires a static point, line-list/strip, or triangle-list/strip/fan topology ». |
| **Après** : `lib-162a23a4-tes` (`6b0d1235…`) | Triangles, directs et indexés : 1 488 pixels couverts, 0 écart, 18 invocations VS. Lignes, directes et indexées : 159 pixels couverts, 0 écart, 12 invocations VS. Adjacence : refusée à `vkEndCommandBuffer` avec `VK_ERROR_FEATURE_NOT_PRESENT`, « Portable PerVertexKHR draws do not support this primitive topology. » |
| **Mutation** : `MVKCmdDraw.mm:222` relit la topologie statique du pipeline | Détectée, sortie 2. Triangles : 1 112 pixels en écart sur 1 488 ; lignes : 53 sur 159. |

**Preuves.** Les dossiers suivants de `build/astra/` ont chacun leur `EVIDENCE.sha256` :
- `dyntopo-before-a07dcc0b/` ;
- `dyntopo-before-0acbd138/` ;
- `dyntopo-after-162a23a4/` ;
- `dyntopo-mutation-162a23a4/`.

## 4. Le correctif (`162a23a4`)

**Analyse du rejeu.** La capture, les tables de rejeu et le pipeline de rejeu ne dépendent que de la classe de topologie, sauf en deux endroits.

- **La topologie exacte à l'encodage.** L'encodage la lisait sur le pipeline. Or `MVKCmdSetPrimitiveTopology` ne gardait que le `MTLPrimitiveType`, qui ne distingue pas un éventail d'une liste.
  - L'état de rendu garde maintenant aussi la topologie Vulkan (`vkPrimitiveTopology`).
  - L'enregistrement suit la dernière valeur fixée, comme pour `patchControlPoints`.
  - L'encodage direct, indexé et indirect lit la topologie effective.
- **La capture en classe triangle.** Elle est réservée aux listes de triangles statiques. Un pipeline à topologie dynamique capture en classe point, comme les bandes et les éventails statiques.
  - **Erreur corrigée en cours de route.** Cette décision lisait `_vkPrimitiveTopology` avant son initialisation (`initMTLRenderPipelineState` s'exécute avant l'initialisation de la topologie). La validation Metal a arrêté le premier essai. La décision est maintenant prise sur `pCreateInfo` et gardée dans `_perVertexCapturesTriangleLists`.

**Refus conservé.** Une valeur dynamique qui n'est pas portable (adjacence, patchs) est refusée à l'enregistrement, avec `VK_ERROR_FEATURE_NOT_PRESENT`. La soumission ne change pas.

## 5. Régression complète : `build/astra/final-r6-162a23a4/`

Tout tourne sous validation Metal, sauf la CTS en mode `plain` (et, comme avant, les cas indirects ordinaires du runner TES, sous validation API seule). `EVIDENCE.sha256` compte 2 552 entrées (sha256 du manifeste `ddc29301…`).

| Étape | Résultat |
| --- | --- |
| Oracles de perte | 0 écart inattendu, 24 exécutions « blocker » connues |
| Suite de perte, binaire, continuation, oracles TES | 12/12, 21/21, 40/40, 14/14 |
| Attachements séparés | 0 écart inattendu |
| Matrice indirecte | 127/127 |
| TES restreint | 142/142 |
| Mesh | 41/41 |
| Contrôles hôte | 10 suites PASS |
| CTS mesh | 9 réussites, inchangé |
| CTS `fragment_shading_barycentric` | Voir ci-dessous : **pas vert** |

**La CTS barycentrique, cas par cas face à `final-r5-7ce08935`.** Aucun cas ne passe de Pass à Fail. Tous les changements sont dans `weights.*.pipeline_topology_dynamic`.

| Changement | `plain` | validé |
| --- | --- | --- |
| Refus devenu réussite | 82 | 90 |
| Refus devenu **résultat faux** | **38** | **30** |
| Adjacence : toujours refusée, maintenant à l'enregistrement | 96 | 96 |

**Classement des résultats faux.**

**1. Éventails : 24 cas, dans les deux modes.** Les cas `triangle_fan` de `provoking_first` et `provoking_last`, en 6 sous-types et 2 modes d'interpolation.
- **Ce que fait le test.** Il rend deux fois :
  - une image de test avec un fragment PerVertexKHR ;
  - une image de référence avec un fragment ordinaire, qui ne passe **pas** par PerVertexKHR.
  Les deux pipelines sont créés en `TRIANGLE_LIST` statique, puis reçoivent `TRIANGLE_FAN` en dynamique.
- **Images extraites** (`build/astra/dyntopo-cts-images-162a23a4/`).
  - L'image PerVertexKHR couvre les deux triangles de l'éventail.
  - La référence n'en contient qu'un : l'autre moitié du carré est vide (8 256 pixels en écart).
- **Cause : un défaut préexistant du chemin ordinaire de MoltenVK.** `MVKCmdDraw.mm` choisit la conversion des éventails d'après la topologie statique du pipeline. Quatre endroits sont concernés :

  | Ligne | Fonction |
  | --- | --- |
  | 565 | `MVKCmdDraw::encode` |
  | 847 | `MVKCmdDrawIndexed::encode` |
  | 1506 | `MVKCmdDrawIndirect::encode` |
  | 1902 | `MVKCmdDrawIndexedIndirect::encode` |

  Un éventail dynamique y est dessiné comme une liste. Ce n'est pas PerVertexKHR.
- **Ce qui reste non prouvé.** Le résultat PerVertexKHR n'est pas comparé à une référence juste. L'oracle de la section 3 couvre les éventails, mais pas leurs poids.

**2. Précision MSAA du chemin portable : 6 cas validés, 14 cas `plain`.**
- **Validé : 6 cas.** `msaa_interpolate_at_offset`, en perspective, sur `line_list`, `triangle_list` et `triangle_strip`, pour les deux sommets provoquants.
  - Écart maximal : 2 pour un seuil de 1. En `plain`, `triangle_strip` monte à 4.
  - Les écarts sont concentrés dans les colonnes 125 à 127, où la perspective du test est la plus forte.
- **`plain` seulement : 8 cas de plus.** `triangle_strip`, en perspective, pour les sous-types centroïde et échantillon (qualificateur et fonction).
  - Écart maximal : 5 à 7.
  - Les écarts sont sur l'arête commune aux deux triangles de la bande (x = y), près du coin (127, 127).
- **Déterminisme.** Les 14 cas échouent à l'identique sur trois passes `plain` (`build/astra/dyntopo-cts-strip-plain-162a23a4/`). Les 8 cas de bande réussissent en mode validé.
  - La différence suit donc le mode de compilation des shaders. Ce n'est pas un aléa.
- **Ces écarts ne viennent pas de l'admission.** C'est prouvé pour les listes de triangles, et déduit du chemin de code pour les lignes et les bandes.
  - **Lignes et bandes (déduit, non mesuré).** Le pipeline dynamique et le pipeline statique y prennent le même chemin : capture en classe point, même topologie à l'encodage, même pipeline de rejeu. Or le pipeline de rejeu ne dépend que de la classe (`MVKPipeline.mm:1647`).
  - **Listes de triangles.** Seule la classe de capture diffère.
    - Une bibliothèque A/B force la capture en classe triangle, comme pour une liste statique (`build/astra/dyntopo-ab-list-capture-162a23a4/`, `880114ec…`, non commitée).
    - Sur les 12 cas `triangle_list`, en `plain` et en validé, elle donne les mêmes verdicts et des images **identiques au bit près** à `lib-162a23a4-tes`.
- **Pourquoi ces écarts n'étaient pas visibles.** Le groupe statique `weights.*.pipeline_topology_static` n'a pas de variante MSAA : ces écarts n'apparaissaient donc pas. Un pipeline statique de même forme donnerait le même résultat. C'est une limite de précision du chemin portable en MSAA, que l'admission rend visible.

**Durée de la CTS validée.** 18 s au lieu de 161 s pour `final-r5`. Les 2 851 résultats sont présents et `crashes.txt` est vide. Le temps gagné vient du cache de shaders Metal : chaque paquet de 200 cas prend environ 1 s au lieu de 7 à 20 s.

**Sommet provoquant « dernier ».** Sur les 108 cas `provoking_last.pipeline_topology_dynamic`, 45 passent maintenant sur le GPU en mode validé (41 en `plain`). La formule de la CTS, `Σ in_color[i]·bc[i]`, ne dépend pas de l'ordre des sommets. Ces cas ne prouvent donc pas l'ordre du sommet provoquant « dernier ». Ils rendent toutefois sur le GPU des pipelines créés avec `VK_PROVOKING_VERTEX_MODE_LAST_VERTEX_EXT`. La phrase « Aucun essai GPU ne l'utilise » de `PerVertexNonTES-STATE.md` (section 3) est à nuancer en ce sens.

## 6. Écart au contrat

- **Admis :** `VK_DYNAMIC_STATE_PRIMITIVE_TOPOLOGY` sur les pipelines PerVertexKHR portables sans tessellation. Les valeurs admises sont les points, les lignes (listes, bandes) et les triangles (listes, bandes, éventails), avec des dessins directs, indexés et indirects.
- **Refusés à l'enregistrement :** les valeurs à adjacence et les patchs.
- **Coût :** un pipeline à topologie dynamique capture toujours en classe point, même pour une liste de triangles.

## 7. Décisions demandées

1. **Le défaut des éventails dynamiques du chemin ordinaire.** Il est hors PerVertexKHR.
   - Le correctif serait petit : les quatre endroits de `MVKCmdDraw.mm` liraient la topologie effective de l'encodeur (`getVkGraphics().getPrimitiveTopology()`, ajoutée par `162a23a4`) au lieu de la topologie statique.
   - Il toucherait tous les dessins MoltenVK, pas seulement PerVertexKHR.
   - Sans ce correctif, les 24 cas d'éventail restent faux dans la CTS.
2. **Les 6 à 14 écarts de précision MSAA du chemin portable.** Ils sont à accepter comme limite documentée, ou à ouvrir comme prochain écart. Les ouvrir demanderait d'abord un oracle statique en MSAA, puisque la CTS n'en a pas.
3. **Garder `162a23a4`.** L'admission est juste là où elle est vérifiée, et aucun cas CTS ne régresse. La CTS n'est pas verte pour autant.
