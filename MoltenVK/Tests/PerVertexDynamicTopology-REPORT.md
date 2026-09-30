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
- **Attribution revue en section 11.** Ces écarts ne viennent pas du chemin portable : l'écart d'offset vient de la traduction générique de SPIRV-Cross, et les écarts propres au mode `plain` du pipeline de référence.

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
2. **Les 6 à 14 écarts de précision MSAA du chemin portable.** Ils sont à accepter comme limite documentée, ou à ouvrir comme prochain écart. Les ouvrir demanderait d'abord un oracle statique en MSAA, puisque la CTS n'en a pas. (Traité en section 11, qui revoit aussi l'attribution.)
3. **Garder `162a23a4`.** L'admission est juste là où elle est vérifiée, et aucun cas CTS ne régresse. La CTS n'est pas verte pour autant.

## 8. Suite de la revue d'Astra (30 septembre 2026)

Verdict d'Astra : `162a23a4` reste dans l'admission expérimentale, sans que les éventails dynamiques ni le MSAA soient déclarés qualifiés. Trois suites sont demandées, chacune en série de commits séparée :
- corriger le défaut des éventails du chemin ordinaire dans un changement séparé ;
- qualifier les éventails PerVertexKHR contre une référence indépendante, triangulée explicitement, qui vérifie les poids et l'ordre des sommets ;
- traiter les écarts MSAA comme un défaut ouvert, au seuil CTS inchangé, avec un cas offset et un cas de bande comparés en statique et en dynamique, avec et sans validation Metal.

## 9. Éventails dynamiques du chemin ordinaire (`d9bc1271`, `fb3970cc`)

**Le défaut.** Metal n'a pas d'éventail : MoltenVK dessine un éventail en triangles indexés. Les quatre commandes de dessin choisissaient cette conversion d'après la topologie statique du pipeline.

| Ligne de `MVKCmdDraw.mm` | Fonction |
| --- | --- |
| 565 | `MVKCmdDraw::encode` |
| 847 | `MVKCmdDrawIndexed::encode` |
| 1506 | `MVKCmdDrawIndirect::encode` |
| 1902 | `MVKCmdDrawIndexedIndirect::encode` |

`upstream/main` (`a63d4863`, 24 septembre 2026) a le même défaut aux quatre endroits.

**L'oracle (`d9bc1271`, test seul).** Le harnais de la section 2 gagne :
- un fragment ordinaire, sans PerVertexKHR (`pervertex-dynamic-topology.frag`), qui fait passer les mêmes dessins par le chemin ordinaire ;
- les formes `indirect` et `indexed-indirect`, qui atteignent les quatre endroits.

Pour le fragment ordinaire, le nombre d'invocations VS doit être égal entre statique et dynamique, et au moins 6 par dessin : un éventail converti est indexé et peut ombrer un sommet plusieurs fois.

**Le correctif (`fb3970cc`).** Les quatre endroits lisent la topologie effective de l'encodeur (`getVkGraphics().getPrimitiveTopology()`). Rien d'autre ne dépend de l'éventail à la création du pipeline : la seule autre lecture est l'avertissement sur le redémarrage (`MVKPipeline.mm:960`).

| Bibliothèque | Résultat |
| --- | --- |
| **Avant** : `lib-162a23a4-tes` (runtime identique à `d9bc1271`) | Rouge. Les 4 formes ordinaires de triangles : 362 pixels en écart sur 1 488, 30 invocations VS en statique contre 24 en dynamique. Témoins verts : les 4 formes ordinaires de lignes, et les formes indirectes PerVertexKHR (triangles et lignes). |
| **Après** : `lib-fb3970cc-tes` (`72663e35…`) | Vert. 17 cas sur 17 : triangles et lignes, 4 formes, fragments ordinaire et PerVertexKHR, plus le refus de l'adjacence. |
| **Mutations**, un endroit remis à la topologie statique à la fois | Les 4 détectées, chacune par sa forme : 362 pixels en écart. |
| **Mutation** de `MVKCmdDraw.mm:1130` (encodage indirect PerVertexKHR, `162a23a4`) | Détectée par `triangles:indirect:pervertex` : 1 112 pixels en écart. Cette ligne n'était couverte par aucun oracle avant ce jalon. |

**CTS ordinaire.** Aucun cas CTS ordinaire n'utilise un éventail en topologie dynamique ; seule la référence de la CTS barycentrique le fait. Le filet de régression rassemble les 562 cas qui touchent les éventails ou la topologie dynamique hors barycentrique (`build/cts-lists/ordinary-fan-topology.txt`, `e814c9d5…`) :
- les éventails statiques de `dEQP-VK.draw.*` ;
- `input_assembly` pour les éventails, et `restart_mix` en topologie dynamique ;
- `extended_dynamic_state.*.topology_*` ;
- les cas de topologie dynamique de `rasterization` et de `dynamic_state`.

Avant et après, sous validation : 258 réussites, 5 échecs, 299 non pris en charge, identiques cas par cas. Les 5 échecs sont antérieurs : deux `restart_disabled_triangle_fan` (Metal ne sait pas désactiver le redémarrage) et trois `bind_unused_ms` refusés.

**Preuves** (chaque dossier de `build/astra/` a son `EVIDENCE.sha256`) :
- `dyntopo-ordinary-before-d9bc1271/` ;
- `cts-ordinary-before-d9bc1271/` ;
- `dyntopo-ordinary-after-fb3970cc/` ;
- `dyntopo-ordinary-mutations-fb3970cc/` ;
- `cts-ordinary-after-fb3970cc/`.

**Effet sur la CTS barycentrique** (`final-r7`, section 12). Avec une référence juste, 22 des 24 cas d'éventail passent en validé et 14 en `plain`. Ceux qui échouent encore sont tous MSAA en perspective. Ils rejoignent la famille de la section 11, avec des écarts identiques à ceux de la bande.

## 10. Éventails PerVertexKHR : référence triangulée indépendante (`99796ed3`, test seul)

**La référence.**
- **Même rendu, sans PerVertexKHR.** Le harnais rend les mêmes trois dessins (liste, bande, éventail) par un pipeline ordinaire en liste de triangles (`pervertex-dynamic-reference.vert`).
- **Sommets.** Chaque sommet de la référence est un coin d'un triangle explicite. Il porte les valeurs des trois coins en `flat`, et un poids barycentrique à un seul 1, interpolé.
- **Ordre des coins.** Il suit la table d'ordre barycentrique de Vulkan, sommet provoquant « premier », telle que la CTS l'encode (`getDataVertexFormula` de `vktFragmentShadingBarycentricTests.cpp`) :
  - liste : (3p, 3p+1, 3p+2) ;
  - bande : (p, pair ? p+1 : p+2, pair ? p+2 : p+1) ;
  - éventail : (p+1, p+2, 0).
- **Fragment `weights`.** R et G portent les deux premiers poids barycentriques ; B combine les trois valeurs de sommet avec des poids fixes par indice. Une permutation cohérente des coins et des poids garde `Σ c[i]·bc[i]`, la seule grandeur que mesure le groupe `weights` de la CTS, mais change les trois canaux.
- **Témoin négatif intégré.** La même référence, avec les coins de chaque triangle tournés d'un cran, doit différer.

**Résultat** sur `lib-fb3970cc-tes`, 4 formes (directe, indexée, indirecte, indexée indirecte) :
- pipeline statique et pipeline dynamique égaux à la référence au bit près (0 pixel en écart sur 1 488) ;
- référence tournée : 1 488 pixels en écart sur 1 488.

**Ce que seule cette référence voit.** Deux mutations remplacent l'ordre de l'éventail (p+1, p+2, 0) par (0, p+1, p+2), c'est-à-dire la même rotation pour le pipeline statique et pour le pipeline dynamique : l'une dans la table CPU (`MVKPerVertexReplay.h`, dessins directs), l'autre dans la table GPU (`MVKCommandPipelineStateFactoryShaderSource.h`, dessins indirects).

| Oracle | Mutation CPU (`triangles:direct`) | Mutation GPU (`triangles:indirect`) |
| --- | --- | --- |
| Statique contre dynamique (section 2) | **Aveugle** : PASS, 0 écart | **Aveugle** : PASS, 0 écart |
| Référence triangulée | Détectée : 744 pixels en écart | Détectée : 744 pixels en écart |
| CTS, groupe `weights` (8 cas d'éventail, statiques et dynamiques) | **Aveugle** : 8 réussites | — |
| CTS, groupe `data` : 8 cas `data.provoking_first.dynamic.triangle_fan.*` (`dynamic` y désigne l'indexation dynamique ; la topologie est statique), 8 réussites à `fb3970cc` | Détectée : 8 échecs | — |

**Limites.**
- Seul le sommet provoquant « premier » est couvert : le harnais n'active pas `VK_EXT_provoking_vertex`.
- Les lignes ne sont pas couvertes par cette référence.

**Preuves** :
- `build/astra/dyntopo-weights-99796ed3/` ;
- `build/astra/dyntopo-weights-mutations-99796ed3/`. Ce dossier contient aussi deux journaux `triangles-ights-pervertex.log` : une erreur de ma ligne de commande (zsh a lu `$form:weights` comme un modificateur), rejetée par le programme avec « Unknown case », puis relancée correctement.

## 11. MSAA : statique contre dynamique, avec et sans validation (`22bf878a`, `7c932571`, test seul)

**Le test** (`PerVertexMSAAWeightsTests.mm`). Il reprend le test `weights` de la CTS : mêmes sommets et couleurs, sommets de droite à w = 16, MSAA 4× avec échantillonnage par échantillon, 128 × 128.
- **Images rendues.** Pour chaque cas, quatre images :
  - le fragment PerVertexKHR, par un pipeline statique ;
  - le même fragment, par un pipeline à topologie dynamique créé en liste, comme la CTS ;
  - le fragment de référence (couleur interpolée à l'échantillon, sans PerVertexKHR), par ces deux mêmes pipelines.
- **Codes de sortie.**
  - 2 : statique et dynamique diffèrent.
  - 4 : ils sont identiques, mais l'image PerVertexKHR dépasse le seuil CTS de 1 face à la référence. C'est le défaut ouvert, au seuil inchangé.
  - 0 : identiques et dans le seuil.
- **Modes.** Le runner prend un mode `validated` ou `plain` et vide le MSL généré (`MVK_CONFIG_SHADER_DUMP_DIR`). Le mode `plain` n'est utilisé que pour ce point, à la demande d'Astra.

**Résultats** sur `lib-fb3970cc-tes` :

| Cas | Mode | Statique contre dynamique | Face à la référence (seuil 1) |
| --- | --- | --- | --- |
| offset, liste | validé | identiques (test et référence) | 148 pixels au-dessus, écart 2, colonnes 125 à 127 |
| offset, liste | `plain` | identiques | 148 pixels, écart 2, colonnes 125 à 127 |
| offset, bande | validé | identiques | 148 pixels, écart 2, colonnes 125 à 127 |
| offset, bande | `plain` | identiques | 168 pixels, écart 4, dont 21 sur l'arête commune |
| échantillon, bande | validé | identiques | 0 pixel, écart 0 |
| échantillon, bande | `plain` | identiques | 25 pixels, écart 5, tous sur l'arête commune |

Ces chiffres reproduisent ceux de la CTS au pixel près.

**Attribution.**
1. **L'admission n'y est pour rien.** Dans tous les cas et les deux modes, les images statiques et dynamiques sont identiques au bit près, pour PerVertexKHR comme pour la référence. C'est la mesure qui manquait pour les bandes : jusqu'ici, ce point n'était déduit que du chemin de code.
2. **L'écart commun aux deux modes vient de la traduction de l'offset par SPIRV-Cross, pas de PerVertexKHR.**
   - Le MSL généré lit `interpolate_at_offset(gl_SamplePosition - float2(0.5) + 0.4375)`. SPIRV-Cross ajoute 0,4375, et non 0,5, à tout `interpolateAtOffset`, avec ce commentaire dans `spirv_msl.cpp` : « It has to be (1/2 - 1/16) and not 1/2, or several CTS tests subtly break on Intel ». Le point interpolé est donc décalé de 1/16 de pixel.
   - Le contrôle `ordinary-offset-list` applique `interpolateAtOffset` à une entrée ordinaire, sans PerVertexKHR. Il donne le même écart (148 pixels, écart 2, colonnes 125 à 127), et une image **identique au bit près** à l'image PerVertexKHR, dans les deux modes.
   - La CTS ordinaire d'interpolation par offset (`multisample_interpolation.*offset*`, 73 cas) passe : 24 réussites, 1 échec antérieur (`nonuniform_interpolant_indexing.offset`), 48 non pris en charge. Ses géométries n'ont pas la perspective forte du test barycentrique.
3. **Les écarts propres au mode `plain` viennent de la référence, pas de PerVertexKHR.**
   - Entre `plain` et validé, les images PerVertexKHR sont identiques au bit près dans les trois cas, et le MSL vidé est identique fichier pour fichier.
   - Ce sont les images de **référence** des bandes (pipeline ordinaire) qui changent : 77 pixels, écart maximal 5, tous sur l'arête commune aux deux triangles.
   - À MSL égal, la différence naît donc sous le MSL, dans la compilation ou l'exécution Metal du pipeline de référence selon que la validation est active ou non. Je ne sais pas laquelle des deux références est juste.
   - Le MSL vidé couvre les shaders de l'application ; les shaders de capture et de rejeu de MoltenVK n'y figurent pas. Cela ne change pas la conclusion, puisque les images PerVertexKHR ne varient pas.

**Défaut ouvert, au seuil CTS inchangé.** 8 cas en validé : l'offset en perspective sur ligne, liste, bande et éventail, pour les deux sommets provoquants. 24 cas en `plain`. Aucun n'est déclaré qualifié.

**Preuves** : `build/astra/msaa-weights-22bf878a/`, `build/astra/msaa-weights-7c932571/`, `build/astra/cts-ordinary-offset-fb3970cc/` (liste `build/cts-lists/ordinary-interpolate-offset.txt`).

## 12. Régression complète : `build/astra/final-r7-fb3970cc/`

Mêmes étapes que `final-r6`, plus l'oracle de topologie dynamique complet et le filet CTS ordinaire. `EVIDENCE.sha256` compte 2 596 entrées (sha256 du manifeste `60630397…`).

| Étape | Résultat |
| --- | --- |
| Oracles de perte | 0 écart inattendu, 24 exécutions « blocker » connues |
| Suite de perte, binaire, continuation, oracles TES | 12/12, 21/21, 40/40, 14/14 |
| Attachements séparés | 0 écart inattendu |
| Matrice indirecte | 127/127 |
| TES restreint | 142/142 |
| Mesh | 41/41 |
| Contrôles hôte | 10 suites PASS |
| Topologie dynamique | 17/17 |
| CTS ordinaire (562 cas) | 258 réussites, 5 échecs antérieurs, 299 non pris en charge |
| CTS mesh | 9 réussites, inchangé |
| CTS `fragment_shading_barycentric` | validé 1 325 réussites (+22 face à `final-r6`), `plain` 1 309 (+14) ; aucun cas de Pass à Fail |

**Résultats faux restants** dans la CTS barycentrique : tous dans la famille MSAA de la section 11.
- Validé, 8 cas : l'offset sur ligne, liste, bande et éventail.
- `plain`, 24 cas : les mêmes 8, plus les sous-types centroïde et échantillon sur bande et sur éventail.

## 13. Contrat et décisions demandées

**Contrat.**
- L'extension publique reste fermée, et l'admission reste expérimentale.
- Les éventails dynamiques sont vérifiés contre la référence triangulée, en sommet provoquant « premier ».
- Le MSAA reste un défaut ouvert, au seuil CTS inchangé.
- TES et soumission restent gelés.

**Décisions.**
1. **Écart d'offset.** Il vient de la traduction générique de SPIRV-Cross. Faut-il l'ouvrir, puisqu'il touche tout `interpolateAtOffset` sur GPU Apple et pas seulement PerVertexKHR ? Le décalage de 1/16 est un compromis voulu pour Intel ; le changer demande des preuves sur Intel, qui restent pour la fin.
2. **Écarts propres au mode `plain`.** Ils naissent dans le pipeline de référence ordinaire, sous le MSL. Faut-il les suivre, ou les documenter ?
3. **Éventails en sommet provoquant « dernier ».** Ils restent non vérifiés par la référence triangulée, faute de `VK_EXT_provoking_vertex` dans le harnais.

## 14. Deuxième avis d'Astra (30 septembre 2026)

- Les deux défauts MSAA sont ouverts. `162a23a4` reste expérimental.
- Le sommet provoquant « dernier » est **explicitement non qualifié** : les réussites CTS `weights` ne prouvent pas son ordre, et aucun oracle ne le vérifie.
- Trois demandes :
  - un A/B ciblé `0,4375 → 0,5` sur Apple, au seuil CTS inchangé, sans correctif générique avant la validation Intel ;
  - un oracle d'interpolation ordinaire, échantillon par échantillon, avec des positions attendues calculées indépendamment ;
  - une référence triangulée avec des `w` différents, qui distingue les interpolations perspective et sans perspective.

## 15. Défaut 1 : l'offset de SPIRV-Cross, A/B `0,4375 → 0,5`

**La bibliothèque A/B** (`build/astra/lib-dd2a8957-offset-half/`, `b139eb61…`, non commitée) :
- construite à `dd2a8957`, avec un clone de SPIRV-Cross à `6af5a67f` où `spirv_msl.cpp` émet `+ 0.5` au lieu de `+ 0.4375` (`mutation.diff`) ;
- le changement est commité dans ce clone seulement (`5114c453…`, enregistré par `PROVENANCE.txt`) ;
- le dépôt SPIRV-Cross partagé n'est pas modifié.

**Résultats au seuil CTS de 1**, face à `lib-fb3970cc-tes`, dont le runtime et SPIRV-Cross sont ceux de `dd2a8957` avant l'A/B :

| Essai | `+ 0.4375` | `+ 0.5` (A/B) |
| --- | --- | --- |
| `msaa-weights` offset, liste (validé et `plain`) | 148 pixels, écart 2 | **0 pixel, écart 0** |
| `msaa-weights` offset, bande, validé | 148 pixels, écart 2 | **0 pixel, écart 0** |
| `msaa-weights` offset, bande, `plain` | 168 pixels, écart 4 | 25 pixels, écart 5, tous sur l'arête commune (défaut 2) |
| `msaa-weights` échantillon, bande (témoin) | validé 0 ; `plain` 25 pixels, écart 5 | inchangé |
| `msaa-weights` offset ordinaire, liste | 148 pixels, écart 2 | **0 pixel, écart 0** |
| CTS barycentrique, validé | 8 résultats faux (offset) | **0 résultat faux** ; 8 cas de Fail à Pass, aucun de Pass à Fail |
| CTS barycentrique, `plain` | 24 résultats faux | 20, tous bande ou éventail (défaut 2) ; 4 cas de Fail à Pass, aucun de Pass à Fail |
| CTS ordinaire `multisample_interpolation.*offset*` (73 cas), validé et `plain` | 24 réussites, 1 échec, 48 non pris en charge | identique cas par cas |

Avec `+ 0.5`, l'image d'offset PerVertexKHR est identique au bit près à l'image d'offset ordinaire et à la référence, dans les deux modes.

**Conclusion.** Sur Apple M4, le décalage de 1/16 explique à lui seul l'écart d'offset, et `+ 0.5` ne dégrade aucun cas CTS mesuré. Deux listes ont été mesurées : la liste barycentrique exécutable (2 851 cas) et `multisample_interpolation.*offset*` (73 cas). Les autres groupes CTS qui utilisent `interpolateAtOffset`, sous `glsl` par exemple, n'ont pas été lancés. Le commentaire de SPIRV-Cross dit que `+ 0.5` casse des tests CTS sur Intel ; ce n'est pas vérifié ici. Aucun correctif n'est proposé avant la validation Intel.

**Preuves** (`build/astra/`, chacune avec son `EVIDENCE.sha256`) :
- `lib-dd2a8957-offset-half/` ;
- `msaa-weights-offset-half-dd2a8957/` ;
- `cts-offset-half-dd2a8957/` ;
- `cts-ordinary-offset-plain-fb3970cc/` (ligne de base `plain` de la CTS ordinaire d'offset).

## 16. Défaut 2 : la référence ordinaire en mode `plain`

**L'oracle** (`2f001a79`, test seul). Les cas `samples-list` et `samples-strip` rendent la référence ordinaire avec un fragment qui écrit dans un buffer, pour chaque échantillon :
- sa couleur, non quantifiée ;
- `gl_SamplePosition`.

Chaque échantillon doit se trouver à l'emplacement standard 4× de Vulkan (`standardSampleLocations = VK_TRUE`), et sa couleur doit égaler, à un pas de 8 bits près, l'interpolation perspective calculée en double sur le CPU à cet emplacement. `gl_PrimitiveID` n'est pas utilisé : il demanderait la capacité `Geometry`, que MoltenVK n'expose pas. Le triangle couvrant est choisi sur le CPU ; sur l'arête commune, les deux triangles donnent la même valeur.

**Résultats**, liste et bande, validé et `plain` :
- 65 536 échantillons écrits sur 65 536, tous à l'emplacement standard ;
- erreur maximale sous 5·10⁻⁷ face au CPU, soit l'arrondi flottant ;
- les données par échantillon et l'image résolue sont identiques entre les deux modes.

**Ce que cela montre.** Quand ses échantillons sont observés, l'interpolation ordinaire est juste dans les deux modes. Or l'image résolue de ce fragment, en `plain`, est **juste** : elle est égale à la référence validée. La référence sans effet de bord, elle, diffère en `plain` sur 77 pixels de l'arête commune de la bande. L'observation change donc le résultat.

**Mécanisme.** Sur ces 77 pixels, j'ai modélisé plusieurs hypothèses sur le CPU, avec l'image résolue en entier sur 8 bits :

| Hypothèse | Accord avec l'image `plain` (écart ≤ 1) | Accord avec l'image validée |
| --- | --- | --- |
| Interpolation à chaque échantillon | 52/77 | **77/77** |
| Interpolation au centre du pixel, pour chaque triangle | **77/77** | 53/77 |
| Au premier échantillon couvert | 55/77 | 67/77 |
| Au centroïde des échantillons couverts | 51/77 | 77/77 |

Sur toute l'image, les deux modèles principaux donnent :

| Modèle | Accord avec l'image `plain` | Accord avec l'image validée |
| --- | --- | --- |
| Interpolation à chaque échantillon | 16 359/16 384 | **16 384/16 384** |
| Interpolation au centre du pixel | **16 384/16 384** | 16 360/16 384 |

En `plain`, la référence ordinaire sans effet de bord se comporte donc comme une interpolation au centre du pixel, **au moins** sur les pixels partagés par les deux triangles de la bande. Ailleurs, les deux modèles sont indiscernables à ±1 : je ne peux pas dire si le centre du pixel sert seulement sur l'arête ou partout. L'échantillonnage par échantillon (`sampleShadingEnable`, `minSampleShading = 1`, entrée `sample`) n'y est pas appliqué. Il l'est sous validation Metal, et aussi en `plain` dès que le fragment écrit dans un buffer.
- Le MSL est identique entre les modes : la cause se situe sous le MSL. Elle n'est pas établie davantage.
- La liste, avec la même arête diagonale, n'est pas touchée.

**La CTS ordinaire ne le voit pas.** Le groupe `dEQP-VK.pipeline.monolithic.multisample_interpolation.*` (247 cas) donne des résultats identiques dans les deux modes : 84 réussites, 3 échecs antérieurs (`nonuniform_interpolant_indexing.*`), 160 non pris en charge.

**Rôle de chaque essai.**
- **Détecteur.** C'est `msaa-weights sample-strip` en `plain` : sortie 4, 25 pixels au-dessus du seuil, tous sur la diagonale.
- **Référence vérifiée.** Les cas `samples-*` sont la référence contrôlée par le CPU : ils prouvent que l'interpolation elle-même est juste. Ils ne peuvent pas détecter le défaut, puisque l'observation le fait disparaître.

**Statut.** C'est un défaut du chemin ordinaire en mode `plain`, distinct de PerVertexKHR. Il est suivi, mais pas corrigé.

**Preuves** : `build/astra/msaa-samples-2f001a79/`, `build/astra/cts-multisample-interpolation-fb3970cc/`.

## 17. Référence triangulée avec des `w` différents (`0e1c187c`, `d3d389ee`, test seul)

**La variation de `w`.** Sous `VARIED_W`, le VS du harnais et celui de la référence multiplient la position de clip de chaque sommet par `1 + 0,75 × (v mod 3)`. La position à l'écran ne change pas, mais les trois coins d'un triangle ont des `w` différents. Les cinq SPIR-V par défaut (produits par trois fichiers source) sont inchangés, vérifiés octet par octet.

**Deux nouveaux fragments.**
- `weights-w` : `BaryCoordKHR`, comparé au poids de référence interpolé avec perspective.
- `weights-w-noperspective` : `BaryCoordNoPerspKHR`, comparé au poids interpolé sans perspective (`noperspective`).

**Témoins.** Deux témoins négatifs doivent différer :
- la référence aux coins tournés d'un cran ;
- la référence interpolée dans l'autre mode. Ce second témoin prouve que `w` atteint le résultat.

**Résultats**, 4 formes par fragment, sur `lib-fb3970cc-tes` :
- statique et dynamique égaux à la référence au bit près (0 pixel en écart sur 1 488) ;
- référence tournée : 1 488 pixels en écart ;
- référence de l'autre interpolation : 1 487 pixels en écart, écart maximal 29.

Sur le même binaire, la série complète du harnais passe : 29 cas sur 29 (`build/astra/dyntopo-all-eab15045/`). Elle comprend les 17 cas de la section 9, les 4 formes `weights` et les 8 formes à `w` variés.

**Limites.**
- Sommet provoquant « premier » seulement.
- Triangles seulement.
- Pas de MSAA dans cette référence.

**Preuves** : `build/astra/dyntopo-weights-w-0e1c187c/` (avant le témoin d'interpolation), `build/astra/dyntopo-weights-w-d3d389ee/`, `build/astra/dyntopo-all-eab15045/`.

## 18. État et décisions demandées

**État.**
- L'extension publique reste fermée. L'admission de `162a23a4` reste expérimentale.
- Les éventails dynamiques sont vérifiés contre la référence triangulée, poids et ordre, avec ou sans perspective et avec des `w` variés, en sommet provoquant « premier ».
- **Défaut 1** (offset SPIRV-Cross) : ouvert. L'A/B montre que `+ 0.5` supprime tous les résultats faux validés sur Apple M4, sans régression CTS mesurée. Il n'y a pas de correctif avant la validation Intel.
- **Défaut 2** (référence ordinaire en `plain`) : ouvert et caractérisé. C'est une interpolation au centre du pixel sur l'arête commune de la bande, sous le MSL. Il est hors PerVertexKHR.
- **Sommet provoquant « dernier »** : explicitement non qualifié.
- TES et soumission restent gelés.

**Décisions demandées.**
1. **Défaut 1.** Préparer le correctif `+ 0.5` pour SPIRV-Cross, en attente des preuves Intel, ou attendre le passage Intel pour décider ?
2. **Défaut 2.** Le signaler comme comportement Metal, ou chercher un contournement dans MoltenVK ? Ce contournement forcerait l'exécution par échantillon, comme le fait un effet de bord. Dans les deux cas, cela sort de PerVertexKHR.

## 19. Troisième avis d'Astra (30 septembre 2026)

- Préparer le patch expérimental `+ 0.5` dans un clone isolé, sans intégration générique. Les cas Intel cités par SPIRV-Cross, et les autres usages d'`interpolateAtOffset`, restent à vérifier.
- Préparer un signalement reproductible du défaut 2, avant tout contournement dans MoltenVK : une reproduction en Metal seul, sans instrumentation, avec les mêmes états MSAA et une comparaison au modèle CPU. Astra déconseille une écriture factice dans MoltenVK : l'oracle instrumenté lit aussi `gl_SampleID` et `gl_SamplePosition`, donc il n'isole pas l'effet de l'écriture.
- Réserve : le verdict de l'oracle échantillon par échantillon pouvait accepter une couverture partielle.

## 20. Candidat SPIRV-Cross `+ 0.5` (clone isolé, non intégré)

**Emplacement.** Le clone est `build/astra/spirv-cross-offset-half/clone`, cloné depuis le fork à `6af5a67f`, sur la branche `experimental/interpolate-at-offset-half`. Sa poussée est désactivée (`DISABLED-no-push`). Le fork SPIRV-Cross n'est pas modifié.

**Le commit `6e51dee7`**, « MSL: Offset interpolateAtOffset by 1/2 instead of 1/2 - 1/16 (experimental) », change :
- `spirv_msl.cpp` : `+ 0.5`, avec un commentaire qui garde la raison Intel et la marque comme non vérifiée ;
- les trois références MSL qui contenaient `+ 0.4375` :
  - `shaders-msl/asm/frag/pull-model-interpolation.asm.msl23.frag`, avec et sans optimisation ;
  - `shaders-msl-no-opt/frag/pull-interpolant-access-chain.msl23.frag`.

Le patch est exporté dans `patch/0001-MSL-Offset-interpolateAtOffset-by-1-2-instead-of-1-2.patch`.

**Vérification** par le `test_shaders.py` de SPIRV-Cross, sur ces trois tests (compilation Metal comprise) :

| CLI | Références | Résultat |
| --- | --- | --- |
| Base (`6af5a67f`) | d'origine | 3 sur 3 conformes |
| Candidat (`6e51dee7`) | mises à jour | 3 sur 3 conformes |
| Base | mises à jour | 3 sur 3 non conformes : les tests voient le changement |

La bibliothèque A/B de la section 15 venait du commit `5114c453` du même clone : même changement de code, sans le commentaire ni les références. J'ai reconstruit une bibliothèque à partir du candidat `6e51dee7` (`build/astra/lib-d99c34fb-candidate-6e51dee7/`, `5d7dda4c…`). Les 8 exécutions `msaa-weights` y donnent les mêmes verdicts et des images identiques au bit près (32 images sur 32) à celles de l'A/B (`build/astra/msaa-weights-candidate-d99c34fb/`). Les résultats CTS de la section 15 n'ont pas été relancés avec ce binaire ; le MSL émis est la même chaîne `+ 0.5`.

**Non fait.**
- La suite complète de `test_shaders.py` n'a pas été lancée : les versions Homebrew de glslang et SPIRV-Tools diffèrent de celles que SPIRV-Cross fixe.
- Pas de validation Intel.
- Pas de CTS hors des deux listes de la section 15.

**Preuves** : `build/astra/spirv-cross-offset-half/` (`EVIDENCE.sha256`, hors clone et builds).

## 21. Défaut 2 : reproduction en Metal seul

**Le programme** (`MoltenVK/Tests/MetalRepro/SampleShadingStrip.mm`, runner `run-sample-shading-strip.sh`, sans MoltenVK) :
- **Shaders.** Le MSL exact que MoltenVK génère pour le fragment de référence du cas `sample-strip` de `PerVertexMSAAWeightsTests.mm`, qui reprend `dEQP-VK.fragment_shading_barycentric.weights.*.msaa_sample_qualifier.triangle_strip` : VS, et FS avec entrée `sample_perspective` et paramètre `[[sample_id]]` inutilisé.
- **Options de compilation.** Celles que MoltenVK emploie pour ces shaders : `MathMode Fast`, `MathFloatingPointFunctions Fast`, `PreserveInvariance` désactivé. Elles ont été relevées par `MVK_CONFIG_DEBUG=1` à `c11f73c6`, avec le binaire de `msaa-weights-22bf878a` (`metal-repro-92d41760/moltenvk-compile-options/`).
- **États.** 128 × 128, `RGBA8Unorm`, `rasterSampleCount = 4`, résolution MSAA à la fin de la passe, géométrie CTS avec w = 16.
- **Comparaison.** Le programme compare l'image résolue à deux modèles calculés sur le CPU en double, aux emplacements standard 4× : interpolation à chaque échantillon, et interpolation au centre du pixel.

**Variantes du fragment**, pour répondre à la réserve d'Astra :
- le MSL tel que généré ;
- sans `[[sample_id]]` ;
- lecture non repliable de `sample_id` par un buffer constant qui vaut 0 ;
- incrément atomique d'un buffer, **sans** lire ni `sample_id` ni la position ;
- écritures de l'oracle (couleur et position par échantillon).

**Dessins.**
- bande ;
- liste CTS non indexée ;
- liste indexée dans l'ordre de la bande (0 1 2 1 2 3) ;
- éventail tel que MoltenVK le dessine : sommets CTS de l'éventail, triangles indexés 1 2 0 2 3 0.

**Résultats** (`metal-repro-f50a79bb`, 40 exécutions) :

| Fragment | Bande ou éventail indexé, sans validation | Liste ou liste indexée, sans validation | Tout dessin, validation Metal |
| --- | --- | --- | --- |
| MSL tel que généré | 25 pixels à écart jusqu'à 5, sur l'arête commune ; modèle du centre du pixel 16 384/16 384 | par échantillon | par échantillon |
| Sans `[[sample_id]]` | mêmes 25 pixels | par échantillon | par échantillon |
| Lecture non repliable de `sample_id` | mêmes 25 pixels | par échantillon | par échantillon |
| Incrément atomique seul | par échantillon ; 65 536 invocations comptées | par échantillon | par échantillon |
| Écritures de l'oracle | par échantillon | par échantillon | par échantillon |

**Ce que cela établit.**
1. **Le défaut est dans Metal.** Pour la bande, l'image Metal seul est identique au bit près à la référence MoltenVK, en `plain` comme en validé. L'éventail indexé donne une image identique à celle de la bande, donc le même accord avec les modèles (le modèle du centre du pixel l'explique sur 16 384 pixels sur 16 384).
2. **Ce qui rétablit l'exécution par échantillon :** une écriture en mémoire, même sans lecture de `sample_id` ni de la position. Une lecture de `sample_id`, même non repliable, ne suffit pas. *(Retiré en section 24 : cette lecture n'atteignait qu'un alpha déjà saturé en `RGBA8Unorm`.)*
3. **Le déclencheur** n'est ni la primitive bande seule, ni le partage de sommets. La bande et l'éventail indexé divergent ; la liste et la liste indexée dans l'ordre de la bande restent justes. Je ne l'ai pas isolé davantage.
4. Hors de l'arête commune, les deux modèles restent indiscernables à ±1.

**Signalement.** `MoltenVK/Tests/MetalRepro/README.md` est un brouillon en anglais pour Apple (Feedback Assistant). Il est **non envoyé** : l'envoi demande ton accord. Aucun contournement n'est fait dans MoltenVK.

**Preuves** :
- `build/astra/metal-repro-92d41760/` : première passe, et options de compilation ;
- `build/astra/metal-repro-0868a95c/` : avec la liste indexée ;
- `build/astra/metal-repro-f50a79bb/` : avec l'éventail indexé.

## 22. Réserve sur l'oracle échantillon par échantillon (`c11f73c6`)

Le verdict exige maintenant les 128 × 128 × 4 échantillons, tous écrits et tous à l'intérieur d'un triangle. Une couverture partielle devient une erreur (sortie 2). Nouvelle passe, liste et bande, validé et `plain` : 65 536 échantillons sur 65 536, aucun hors triangle, verdict inchangé (`build/astra/msaa-samples-92d41760/`).

## 23. État et décisions demandées

**État.**
- `162a23a4` reste expérimental et l'extension publique reste fermée.
- **Défaut 1** : un candidat SPIRV-Cross est prêt dans le clone isolé. Il n'est pas intégré ; la validation Intel est prévue à la fin.
- **Défaut 2** : reproduit en Metal seul. Le signalement est prêt, non envoyé. Aucun contournement dans MoltenVK.
- **Sommet provoquant « dernier »** : explicitement non qualifié.

**Décisions demandées.**
1. **Envoyer le signalement à Apple ?** Le brouillon est prêt ; l'envoi reste à ta main.
2. **Défaut 1 : faut-il élargir la mesure avant Intel ?** Par exemple, les groupes CTS `glsl` qui utilisent `interpolateAtOffset`.

## 24. Quatrième avis d'Astra et fin du volet MSAA (30 septembre 2026)

**Avis.**
- Le dossier Apple est prêt à être envoyé par l'utilisateur, après deux nuances.
- Arrêt avant tout contournement dans MoltenVK.
- GO pour un dernier A/B CTS borné du candidat SPIRV-Cross, puis gel jusqu'aux essais Intel.
- Cette qualification ne bloque pas davantage le jalon expérimental PerVertexKHR.

**Les deux nuances du signalement** (`7ad54a6b`).
1. **Formulation.** Le texte décrit une divergence **compatible** avec une interpolation au centre du pixel. La fréquence d'exécution n'est comptée que dans la variante avec incrément atomique (65 536 invocations, une par échantillon). Pour les autres variantes, elle n'est pas mesurée.
2. **Variante retirée.** La variante « lecture non repliable de `sample_id` » est retirée du programme et du texte. Elle n'atteignait qu'un alpha déjà saturé en `RGBA8Unorm`, donc sa dépendance observable n'était pas garantie. Le point 2 de la section 21 est annoté en ce sens.

Nouvelle passe du programme réduit à 4 variantes, 32 exécutions (`build/astra/metal-repro-7ad54a6b/`) : chiffres inchangés, et image de la bande toujours identique au bit près à celle de MoltenVK, dans les deux modes.

Le brouillon `MoltenVK/Tests/MetalRepro/README.md` est prêt. **Il reste à envoyer par l'utilisateur.** Aucun contournement n'est fait dans MoltenVK.

## 25. Dernier A/B CTS du candidat SPIRV-Cross

**Sélection.** J'ai relevé les usages d'`interpolateAtOffset` dans les sources et les données de la CTS : quatre fichiers.
- `vktFragmentShadingBarycentricTests.cpp` et le groupe `multisample_interpolation` monolithique : déjà couverts (section 15).
- **Non couverts jusqu'ici :**
  - `vktDrawMultisampleLinearInterpolationTests.cpp` (`dEQP-VK.draw.*.linear_interpolation.*`, 60 cas) ;
  - les constructions de pipeline non monolithiques de `multisample_interpolation.*offset*` (360 cas).
- La liste compte 420 cas : `build/cts-lists/ordinary-interpolate-offset-remaining.txt`, dont la provenance est dans `ordinary-lists.txt` et `SHA256SUMS`.

**A/B** avec le runner CTS existant :
- base : `lib-fb3970cc-tes`, SPIRV-Cross `6af5a67f` ;
- candidat : `lib-d99c34fb-candidate-6e51dee7` ;
- même runtime MoltenVK dans les deux bibliothèques.

| | Validé | `plain` |
| --- | --- | --- |
| Base | 36 réussites, 384 non pris en charge | 36 réussites, 384 non pris en charge |
| Candidat | 36 réussites, 384 non pris en charge | 36 réussites, 384 non pris en charge |
| Changements de statut | 0 | 0 |

- Les 36 cas exécutés sont les `linear_interpolation` à 1, 2 et 4 échantillons, sans offset, offset minimal et offset maximal (0,4375).
- Les 384 cas non pris en charge sont les bibliothèques de pipeline, les shader objects, et 8 échantillons ou plus.

**Preuves** : `build/astra/cts-offset-remaining-ab/`.

**Gel.** Le candidat est gelé par l'étiquette annotée `candidate-frozen-until-intel` sur `6e51dee7`, dans le clone isolé. Le fork SPIRV-Cross n'est pas modifié.

**Bilan du candidat sur Apple M4.** Il n'y a aucune régression, que ce soit sur les 2 851 cas barycentriques ou sur les 493 cas ordinaires d'offset (73 + 420, dont 432 non pris en charge, donc 61 réellement exécutés). Il corrige les 8 résultats faux validés de l'offset. Il reste non vérifié sur Intel, où l'ancienne valeur était nécessaire selon SPIRV-Cross.

## 26. État à la fin du volet MSAA

- **Admission.** `162a23a4` reste expérimental, et l'extension publique reste fermée.
- **Éventails dynamiques.**
  - Le chemin ordinaire est corrigé (`fb3970cc`).
  - PerVertexKHR est vérifié contre la référence triangulée : poids et ordre, `w` variés, avec et sans perspective, sommet provoquant « premier ».
- **Défaut 1** (offset SPIRV-Cross). Un candidat est prêt et gelé jusqu'aux essais Intel. Sans lui, 8 résultats faux restent en validé dans la CTS barycentrique.
- **Défaut 2** (divergence Metal hors validation). Il est reproduit en Metal seul. Le signalement est prêt, à envoyer par l'utilisateur. Il est hors PerVertexKHR, sans contournement.
- **Sommet provoquant « dernier ».** Explicitement non qualifié.
- **Gelés.** TES et soumission restent gelés.
- **Matériel.** M1, M3 et Intel restent pour la fin.
