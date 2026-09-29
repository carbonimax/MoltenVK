# TES direct après fusion : `firstVertex` et `firstInstance` (M4 Pro, 29 septembre 2026)

Option (a) : contrat restreint, extension fermée par défaut. Tout ce qui suit passe par l'admission TES de test (`MVK_TEST_TES_PERVERTEX_ADMISSION`), que les builds de production ne définissent jamais. Le volet perte de device reste gelé et le protocole de soumission n'est pas touché. **L'extension n'est pas prête pour upstream.**

## 1. Contrat et refus au départ (HEAD `0c3e95bd`)

Le contrat est celui de `PerVertexTES/README.md`. Voici les cas Vulkan valides que ce contrat refusait encore.

**À la création du pipeline**, avec `VK_ERROR_FEATURE_NOT_PRESENT` (`MVKPipeline.mm:1391-1418`) :
- un domaine autre que les triangles, un espacement autre qu'égal, le mode point, ou un nombre de points de contrôle différent de 3 ;
- la spécialisation, un `pNext` ou des `flags` d'étage, ou un point d'entrée autre que `main` ;
- des descripteurs ou des push constants dans le TCS ou le TES ;
- un cache de pipeline ;
- tout état dynamique, l'origine de domaine (`pNext` de l'état de tessellation), le multiview, le multi-échantillonnage et les diviseurs de sommets.

**À l'enregistrement**, où `vkEndCommandBuffer` rend `VK_ERROR_FEATURE_NOT_PRESENT` :
- `firstVertex` ≠ 0, `firstInstance` ≠ 0 et DrawID ≠ 0 (`MVKCmdDraw.mm:136`) ;
- les dessins indexés, plus d'une instance et un masque de vues (`MVKCommandBuffer.mm:564`) ;
- les dessins indirects.

**Sur le GPU**, par une perte du device à la soumission : les niveaux non uniformes, les niveaux au-dessus de 3 et un niveau intérieur NaN.

## 2. Le cas choisi

Le cas retenu est un dessin direct non indexé, d'une seule instance, avec `firstVertex` et `firstInstance` non nuls. C'est le plus petit cas valide encore refusé :
- **Il ne touche que l'enregistrement et l'encodage**, pas la soumission.
- **Le mécanisme existe déjà.** La tessellation ordinaire lance son VS en calcul sur une région stage-in d'origine (`firstVertex`, `firstInstance`).
- **SPIRV-Cross dérive déjà les bons indices de cette origine.** Il déclare `spvDispatchBase [[grid_origin]]` (`spirv_msl.cpp:1665`) et en tire `gl_VertexIndex`, `gl_InstanceIndex`, `gl_BaseVertex` et `gl_BaseInstance` (`spirv_msl.cpp:17720-17775`).
- **Les sorties ne bougent pas.** Elles restent indexées depuis 0, par `gl_GlobalInvocationID`.
  - La formule d'écriture (`spvOut[gl_GlobalInvocationID.y * spvStageInputSize.x + gl_GlobalInvocationID.x]`) est la même dans toutes les variantes du VS. Elle se lit dans le noyau généré, `build/astra/tes-first-after-b3baee52/dump/`.
  - Ce dump ne garde qu'une variante MSL par SPIR-V, la dernière compilée : ici la variante indexée.
  - La dérivation non indexée de `gl_VertexIndex` se lit dans SPIRV-Cross (branche `IndexType::None`). Les sommes mesurées, 33 et 6, la confirment.

Le chemin TES PerVertex lançait la même région à l'origine (0, 0). Il refusait donc les deux paramètres pour ne pas rendre un résultat faux.

Pourquoi pas les autres cas :
- Plusieurs instances et les dessins indexés demandent de changer l'indexation des patchs du générateur.
- L'état dynamique, le cache, la spécialisation et les ressources du TCS ou du TES demandent chacun leur propre qualification.
- Les autres niveaux demandent de nouvelles topologies prouvées.

## 3. L'oracle (`bf8ff8c9`)

Le scénario `first` de `topology.cpp` tourne pour les deux enroulements, ccw et cw.
- **Le montage.**
  - Il dessine deux patchs, de niveaux 2 et 3, à partir du sommet 3. Les sommets 0 à 2 sont des leurres mis à zéro.
  - Le dessin a `firstInstance = 1`.
  - Le VS (`topology.vert -DRESOURCES -DFIRST`) ajoute `gl_InstanceIndex - 1` aux niveaux.
  - Son compteur de stockage additionne aussi `gl_VertexIndex` (33 attendu) et `gl_InstanceIndex` (6 attendu), sur le pipeline ordinaire comme sur le pipeline PerVertex.
- **Tous les contrôles existants du harnais s'appliquent** :
  - couverture et interpolation contre le TES ordinaire ;
  - ordre barycentrique ;
  - modèle CPU ;
  - coordonnées de tessellation au bit près ;
  - `gl_PrimitiveID` en fragment.
- **Chaque paramètre est discriminé séparément, par construction.** La mutation exécutée remet les deux origines à zéro en même temps ; ses chiffres ne séparent donc pas les deux effets :
  - une origine x ignorée donne un patch écarté, un patch déplacé et une somme de sommets de 15 ;
  - une origine y ignorée donne les niveaux 1 et 2 au lieu de 2 et 3, et une somme d'instances de 0.

## 4. Rouge avant, vert après, mutation détectée

| Bibliothèque | `first` ccw | `first` cw |
| --- | --- | --- |
| **Avant** : `lib-a3f02d1c` (sha256 `4e1b069a…`), admission et adaptateur de test. Son runtime est identique à `0c3e95bd` : `git diff a3f02d1c 0c3e95bd -- MoltenVK/MoltenVK MoltenVKShaderConverter ExternalRevisions` est vide. | sortie 1, refus à l'enregistrement : `VK_ERROR_FEATURE_NOT_PRESENT` | idem |
| **Après** : `lib-b3baee52-tes` (sha256 `5868ff17…`) | **PASS** : sommes 33 et 6 sur les deux pipelines, 0 écart de couverture sur 3 136 pixels, écart de valeur maximal 0, coordonnées au bit près | **PASS**, mêmes résultats |
| **Mutation** `mutation-first-origin` : origine remise à (0, 0), refus retiré (sha256 `2ff49023…`) | sortie 2 : 1 568 pixels sur 3 136 en écart de couverture, sommes PerVertex 15 et 0, 57 canaux faux au modèle CPU | non lancée |

Preuves, chacune avec son `EVIDENCE.sha256` :
- `build/astra/tes-first-before-bf8ff8c9/` ;
- `build/astra/tes-first-after-b3baee52/` ;
- `build/astra/tes-runner-b3baee52/`.

## 5. Le correctif (`b3baee52`)

- **`MVKCmdDraw.mm`.** `encodePerVertexTessEval()` reçoit `firstVertex` et `firstInstance` et lance la région stage-in du VS à cette origine. Les deux gardes modifiées ne refusent plus que DrawID ≠ 0 et, à l'encodage, plus d'une instance. Le refus des dessins indexés, à plusieurs instances ou multivues dans `recordPerVertexTessEvalDraw()` ne change pas.
- **Les diviseurs.** Ils restent refusés à la création du pipeline. Aucune liaison à diviseur nul n'a donc besoin du décalage que fait `offsetZeroDivisorVertexBuffers()` en tessellation ordinaire.
- **Les tests remplacés par le nouveau contrat.**
  - Le refus `reject-first-vertex` de `topology.cpp` disparaît, ainsi que le refus `reject-first` du pilote.
  - La garde d'enregistrement avec un pipeline de calcul lié (`reject-first-compute`, `reject-first-instance-compute`) devient `reject-instance-compute`. Elle a le même but, avec deux instances, qui restent refusées.
- **Le runner.** Il gagne `first` pour les deux enroulements et la mutation `mutation-first-origin`. `library()` accepte maintenant un fichier source à muter.
- **Le README.** Le périmètre admis, l'exécution, les oracles et les limites sont mis à jour.

## 6. Régressions

- **Runner TES complet à `b3baee52`** (`run-pervertex-tes-tests.sh`, 8 bibliothèques Debug construites depuis l'archive Git) : **102/102 PASS**.
  - Tout tourne sous `MTL_DEBUG_LAYER=1` et `MTL_SHADER_VALIDATION=1`, sauf les cas indirects ordinaires, qui restent sous validation API seule comme avant.
  - `EVIDENCE.sha256` compte 851 entrées (sha256 du manifeste `676e2cc1…`).
  - Bibliothèque `dev` : sha256 `60a75580…`.
- **Les matrices PerVertex hors TES ne sont pas relancées.** Le diff ne touche que des branches gardées par `usesPerVertexTessEval()` ou `recordedGraphicsPipelineUsesPerVertexTessEval()`, qui n'existent qu'avec l'admission de test.

## 7. Ce qui reste hors du contrat (au jalon `b3baee52` ; état courant au § 10)

- **Pipeline.**
  - Les domaines quads et isolines, les espacements fractionnaires, le mode point et plus de 3 points de contrôle.
  - L'origine de domaine en bas à gauche.
  - Les descripteurs et push constants du TCS ou du TES.
  - Le cache de pipeline, la spécialisation, les points d'entrée autres que `main` et tout état dynamique.
  - Le multiview, le multi-échantillonnage et les diviseurs de sommets.
- **Dessins.**
  - Les dessins indexés, indirects et indexés indirects.
  - Plus d'une instance.
  - DrawID ≠ 0 (multi-draw).
- **Niveaux.** Les niveaux non uniformes, au-dessus de 3, ou avec un niveau intérieur NaN : le device est perdu à la soumission.
- **Non prouvé par cet oracle.**
  - Les attributs de sommet par instance avec un `firstInstance` non nul.
  - `gl_BaseVertex` et `gl_BaseInstance` dans le VS.
  - Ils suivent la même origine stage-in, mais aucun VS du harnais ne les lit.
- **Autres GPU.** Seul un M4 Pro est prouvé. M1, M3 et Intel restent pour la fin.
- **Non fait dans cette passe.** La mesure du coût du dispatch supplémentaire, notée au plan.

## 8. Suite de la revue : l'oracle `first` étendu, en test seul (`c0d9c0dd`)

Astra a validé le jalon de façon bornée. Elle a demandé de vérifier en test seul un attribut par instance et `gl_BaseVertex`/`gl_BaseInstance`, avec des mutations séparées de `firstVertex` et de `firstInstance`.

- **Le montage.**
  - Le VS de `first` lit un attribut par instance (binding 1, `VK_VERTEX_INPUT_RATE_INSTANCE`, `R32_UINT`) : 6 pour l'instance 0, un leurre, et 7 pour l'instance 1.
  - Il ajoute `tag - 7` aux niveaux.
  - Il additionne aussi l'attribut (42 attendu), `gl_BaseVertex` (18) et `gl_BaseInstance` (6), en plus de `gl_VertexIndex` (33) et de `gl_InstanceIndex` (6).
- **Le runtime n'a pas changé depuis `b3baee52`.** L'oracle étendu est vert sans correctif, pour les deux enroulements : les cinq sommes sont exactes sur les pipelines ordinaire et PerVertex (`build/astra/tes-first-extended-c0d9c0dd/`).
- **Deux mutations remplacent la mutation combinée.** Chacune ne retire qu'une coordonnée de l'origine :

| Mutation | Sommes PerVertex (sommet, instance, attribut, base de sommet, base d'instance) | Couverture |
| --- | --- | --- |
| `mutation-first-vertex-origin` : origine (0, `firstInstance`) | 15, 6, 42, **0**, 6 : seules les sommes liées à `firstVertex` changent | 1 568 pixels sur 3 136 en écart |
| `mutation-first-instance-origin` : origine (`firstVertex`, 0) | 33, **0**, **36**, 18, **0** : seules les sommes liées à `firstInstance` changent | 1 568 pixels sur 3 136 en écart |

- Runner TES complet à `c0d9c0dd` : **103/103 PASS** ; `EVIDENCE.sha256` compte 863 entrées (`build/astra/tes-runner-c0d9c0dd/`).
- Les deux lacunes notées au § 7 sont fermées pour ce dessin : l'attribut par instance et `gl_BaseVertex`/`gl_BaseInstance`.

## 9. Le refus de pipeline suivant : des points d'entrée autres que `main`

**Le choix.** C'est le plus petit refus de pipeline indépendant de la soumission.
- La porte d'admission TES refusait tout point d'entrée qui ne s'appelle pas `main` (`MVKPipeline.mm:1403` à `358064bd`).
- Tout le reste du chemin TES PerVertex utilise déjà le `pName` de chaque étage : réflexion, compilation de la capture, rejeu. Le rejeu TES reçoit l'étage TES (`MVKPipeline.mm:2130` à `547c3871`).
- Une seule vraie dépendance restait : le contrôle des ressources du TCS et du TES. `mvkUsesResources()` réfléchissait le point d'entrée `main` par un argument par défaut.
- Les front-ends HLSL nomment couramment leurs points d'entrée autrement que `main`.

**L'oracle (`358064bd`).**
- Le scénario `entry-names` renomme tous les points d'entrée : `vertMain`, `tescMain`, `teseMain`, `fragMain`.
- L'image PerVertex doit concorder avec le pipeline ordinaire construit à partir des mêmes étages renommés. Elle doit aussi être égale, octet par octet, à l'image PerVertex des mêmes shaders nommés `main`.
- Le refus `reject-descriptor-named` garde un descripteur dans un TCS renommé. Il doit rester refusé.

**Le correctif (`547c3871`).**
- La porte réfléchit les ressources du TCS et du TES à leurs vrais points d'entrée.
- `mvkUsesResources()` n'a plus de nom par défaut.
- La spécialisation, le `pNext` et les `flags` d'étage restent refusés.

**Rouge avant, vert après, mutation détectée.**

| Bibliothèque | `entry-names` | `reject-descriptor-named` |
| --- | --- | --- |
| **Avant** : `lib-b3baee52-tes` (`5868ff17…`). Son runtime est identique à `358064bd`, car `c0d9c0dd` et `358064bd` ne touchent que les tests. | Sortie 1 pour les deux enroulements : le pipeline est refusé à cause du nom (« unspecialized main entry points »). | PASS, mais refusé à cause du nom, pas du descripteur. |
| **Après** : `lib-547c3871-tes` (`dc33a8dd…`) | PASS pour les deux enroulements : 0 écart sur 3 136 pixels face au pipeline ordinaire, image égale à celle des shaders nommés `main`. | PASS, refusé cette fois à cause du descripteur. |
| **Mutation** `mutation-entry-main`, où le contrôle du TCS réfléchit encore `main` (`26a2ed89…`) | Sortie 1 : l'exception « Entry point does not exist » de SPIRV-Cross traverse `vkCreateGraphicsPipelines` jusqu'à l'application. | non lancée |

La mutation montre ce qu'aurait fait un correctif qui retirerait seulement le contrôle du nom : une exception C++ qui sort par l'API Vulkan.

**Régressions.**
- Runner TES complet à `547c3871` : **107/107 PASS**.
  - Tout tourne sous `MTL_DEBUG_LAYER=1` et `MTL_SHADER_VALIDATION=1`, sauf les cas indirects ordinaires, sous validation API seule comme avant.
  - `EVIDENCE.sha256` compte 883 entrées (sha256 du manifeste `045ded7a…`). Bibliothèque `dev` : `56eb2984…`.
- Les matrices PerVertex hors TES ne sont pas relancées : le seul changement hors de la porte TES est de supprimer l'argument par défaut de `mvkUsesResources()`. L'autre appelant, le chemin mesh, passait déjà son `pName`.
- Preuves, chacune avec son `EVIDENCE.sha256` : `build/astra/tes-entry-names-before-358064bd/` (le `NOTE.txt` explique un journal sans valeur de test), `build/astra/tes-entry-names-after-547c3871/` et `build/astra/tes-runner-547c3871/`.

Note sur les empreintes des bibliothèques. Deux constructions Debug du même runtime n'ont pas le même sha256 quand leurs chemins de source diffèrent, par exemple l'arbre de travail et l'archive du runner. Chaque bibliothèque est donc désignée par son propre `PROVENANCE.txt`.

## 10. Ce qui reste hors du contrat (à `547c3871`)

- **Pipeline.**
  - Les domaines quads et isolines, les espacements fractionnaires, le mode point et plus de 3 points de contrôle.
  - L'origine de domaine en bas à gauche.
  - Les descripteurs et push constants du TCS ou du TES.
  - Le cache de pipeline, la spécialisation, le `pNext` ou les `flags` d'étage, et tout état dynamique.
  - Le multiview, le multi-échantillonnage et les diviseurs de sommets.
- **Dessins.**
  - Les dessins indexés, indirects et indexés indirects.
  - Plus d'une instance.
  - DrawID ≠ 0 (multi-draw).
- **Niveaux.** Les niveaux non uniformes, au-dessus de 3, ou avec un niveau intérieur NaN : le device est perdu à la soumission.
- **Non prouvé.**
  - Un module SPIR-V dont plusieurs points d'entrée ont le même modèle d'exécution. Les noms sont bien transmis, mais aucun oracle n'en construit un.
  - La mesure du coût du dispatch supplémentaire.
- **Autres GPU.** Seul un M4 Pro est prouvé. M1, M3 et Intel restent pour la fin.

L'extension reste fermée par défaut et n'est pas prête pour upstream.
