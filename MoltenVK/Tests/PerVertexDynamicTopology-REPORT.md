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
| CTS, groupe `data` (8 cas d'éventail) | Détectée : 8 échecs | — |

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
