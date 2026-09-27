# Dessins indirects PerVertexKHR portables : rapport de jalon (M4 Pro, 27 septembre 2026)

Rapport destiné au fil principal, pour revue avant intégration. Rien n'a été poussé ni publié, et aucune PR ou commentaire n'a été créé. La garde publique reste fermée. `PLAN-PERVERTEX-UPSTREAM.md` n'a jamais été écrit par ce travail. Son SHA-256 valait `22429fa0…` au départ ; le fil principal l'a mis à jour à 14:05, en citant l'étape intermédiaire 92/92. Les éléments de mise à jour sur l'état final, 121/121 à `b5a1caec`, sont proposés au §9. Ce fichier n'est pas suivi par git, pour pouvoir citer les SHA de la branche.

Note d'intégration ultérieure : ce rapport décrit le prototype isolé `b5a1caec`. La revue Astra de ce SHA a été favorable sous réserve de séparer le slot de statut indirect de TES ; cette séparation et les tests du binaire commun sont consignés dans `PerVertexIntegration-REPORT.md`. La garantie d'ordre de la section 4 a été précisée après cette revue.

## 1. Verdict

**Jalon atteint sur M4 Pro, dans un contrat borné et explicite.** Les quatre formes rendent des pixels exacts sans troncature :

- `vkCmdDrawIndirect` ;
- `vkCmdDrawIndexedIndirect` ;
- `vkCmdDrawIndirectCount` ;
- `vkCmdDrawIndexedIndirectCount`.

Les arguments, le compte et les indices sont écrits sur le GPU dans la même soumission. Les résultats :

- La matrice GPU passe 121/121, avec la validation Metal API et GPU.
- Les quatre contrôles ordinaires r12 et les quatre contrôles PerVertex directs sont identiques octet par octet aux preuves antérieures.

Ce n'est **pas** un support non borné. Chaque commande indirecte réserve, avant soumission, une capacité finie de records. Au-delà, la commande entière ne fait rien et le périphérique est déclaré perdu. Le §3 explique la limite de ce chemin capture/replay à réservation finie ; le §8 esquisse une continuation possible, non implémentée.

## 2. Isolation, provenance, WIP

| Élément | Valeur |
| --- | --- |
| Worktree MoltenVK | `MoltenVK-indirect-gpu/`, branche `claude/pervertex-indirect-gpu`, base `d608d84c507099909d735843e0af4993aac92661` |
| SPIRV-Cross | worktree détaché `SPIRV-Cross-indirect-gpu/` au pin `4308267dfae1dfc13fc94ebbdcaa624ede6396e6`, **non modifié** (0 fichier modifié). Il sert à l'isolation : le checkout partagé contient un WIP non commité (`spirv_msl.cpp`, etc.). |
| Dépendances | `MoltenVK-indirect-gpu/External/` (ignoré par git) : liens relatifs vers `../../MoltenVK/External/*` en lecture seule, et `SPIRV-Cross` vers `../../SPIRV-Cross-indirect-gpu` |
| Builds et preuves | uniquement sous `MoltenVK-indirect-gpu/build/indirect-gpu/` |

**Commits, dans l'ordre :**

| SHA | Contenu |
| --- | --- |
| `5d6d8508` | production : réservation, admission et planification GPU ; tests CPU d'admission et de préparation |
| `1b28de68` | test Vulkan GPU, shaders, scripts de build et de matrice |
| `4bb7b3e4` | restart indirect |
| `9e0c0d2f` | test de préparation restart |
| `9a038edd` | test hôte du noyau, topologies, stress, contrôle strict des pertes |
| `b5a1caec` | le statut d'admission est lu dans `finish()` de la soumission, avant les fences |

**WIP du checkout initial.** Inspecté au départ : trois fichiers TES du convertisseur (`SPIRVToMSLConverter.cpp`, `PerVertexInputTests.cpp`, `run-per-vertex-input-tests.sh`) et des journaux non suivis. **Aucun n'est nécessaire à l'indirect, donc aucun fichier n'a été reporté.** Rien n'a été écrit dans le checkout partagé.

**Travail concurrent.** Pendant la session, entre 12:54 et 12:57, un travail TES parallèle a modifié le checkout partagé : `MVKCmdDraw.mm`, `MVKCommandBuffer.*`, `MVKCommandEncoderState.*`, `MVKPerVertexScratch.h`, `MVKPipeline.*`, ainsi que `PerVertexTES-WORKLOG.md` et `PerVertexTES/`. Ces changements ne viennent pas de ce travail. **Conflit certain à l'intégration :**

- ce WIP porte `MVKPerVertexScratch::buffers` à 12 entrées et utilise les index 7 à 11 pour le TES ;
- cette branche utilise `buffers[7]` pour le plan indirect.

Il faudra renuméroter ou nommer le tampon de plan au moment de la fusion. Le même WIP touche aussi `MVKCmdDraw.mm` et `MVKCommandBuffer.mm`.

**Bibliothèques testées.** `MoltenVK/Tests/build-pervertex-test-library.sh` les construit depuis un commit exact via `git archive`. Il applique une seule garde de test, qui expose l'extension barycentrique macOS (`test-gate.diff`, 2 lignes), et produit un `PROVENANCE.txt` :

- avant : `d608d84c`, SHA-256 `1056fdcbe419ce6456a8da7a66ba102ce02e5665dfd425194776b9ac46fb09bd` (`build/indirect-gpu/lib-before/`) ;
- final : `b5a1caec`, SHA-256 `e404abe49a80ecd31008b5522576302790bcb829f403aee7a4f6b7e3a330006d` (`build/indirect-gpu/lib-final/`).

Les matrices intermédiaires `matrix-1` à `matrix-3` sont conservées comme historique. Contrairement à r12, la garde multibit multiview n'est **pas** ouverte : le multiview à plusieurs vues reste refusé.

## 3. Contraintes et démonstration

### 3.1 Vulkan

- `VkDrawIndirectCommand` et `VkDrawIndexedIndirectCommand` n'ont aucune borne sur `vertexCount`, `indexCount` ou `instanceCount`, hormis le type `uint32`. Un seul record peut demander 3 sommets × 2³²−1 instances.
- `maxDrawIndirectCount` ne borne que le nombre de dessins (MoltenVK annonce `kMVKUndefinedLargeUInt32`).
- `Count` vaut `min(countBuffer, maxDrawCount)`. Il peut être écrit par le GPU plus tôt dans le même command buffer, ou par une soumission attendue via sémaphore.
- La seule borne dérivable est celle des indices : un dessin indexé doit tenir dans le tampon d'index lié (VUID robustBufferAccess2-08798 de `VkDrawIndexedIndirectCommand`). Elle ne borne pas `instanceCount`.
- Aucune erreur ne peut remonter après un `vkQueueSubmit` réussi, sauf `VK_ERROR_DEVICE_LOST`. La section « Lost Device » l'autorise pour des raisons propres à l'implémentation (« platform resource management », « execution timing out »).

### 3.2 Pourquoi l'architecture initiale ne pouvait pas

Au commit `d608d84c`, l'architecture dimensionnait tout sur le CPU :

- `recordPerVertexDraw` dimensionne capture et replay à partir de comptes CPU ;
- `mvkPopulatePerVertexReplay` construit les tables de replay sur le CPU ;
- `captureParams`, la région stage-in et les tailles de dispatch sont écrits par le CPU ;
- la transaction de soumission réserve tout avant de dispatcher.

Lire les arguments sur le CPU casserait l'ordre Vulkan : les écritures GPU antérieures ne sont pas encore exécutées. Les gardes ne pouvaient donc pas simplement être retirées.

### 3.3 Limite de la réservation finie dans ce chemin capture/replay

Le chemin portable étudié ici, avec un nombre d'encodeurs fixé par le CPU et des records de capture lus par le fragment, ne peut pas rendre tous les dessins légaux avec une réservation finie. L'argument porte sur cette architecture :

1. Le fragment de replay d'une primitive lit ses trois records capturés en mémoire device.
2. Sur Apple3 à Apple10, une barrière de rendu ne peut pas inclure `.fragment` ni `.tile` dans `after`. Source : Metal Feature Set Tables du 21 mai 2026, note 3, copiée dans `build/indirect-gpu/metal-feature-tables-note3.txt` (PDF source `metal-feature-set-tables-2026-05-21.pdf`, SHA-256 `9f31df15…`). À l'intérieur d'un encodeur de rendu, une zone lue par des fragments ne peut donc pas être réécrite par un dessin ultérieur.
3. Le nombre d'encodeurs d'un `MTLCommandBuffer` est fixé par le CPU à l'encodage. Metal n'a pas de boucle d'encodeurs pilotée par le GPU.
4. Dans ce chemin, le volume rendable est au plus (encodeurs fixés par le CPU) × (scratch réservé). Ce produit est fini, alors que le besoin légal atteint 2⁶⁴ records par dessin.

Les voies envisagées pour lever cette limite sont :

- une continuation, où le CPU observe des valeurs GPU au milieu de la soumission (§8) ;
- un chemin mesh sans aller-retour mémoire, qui suppose Metal 3 et une transformation VS→mesh dans SPIRV-Cross.

### 3.4 Solutions évaluées

- **Lots GPU (découpage d'un dessin).** Un découpage par plage d'instances modifierait `gl_BaseInstance` et les index d'attributs par instance quand le diviseur est différent de 1. Il faudrait aussi une base de record dans l'ABI de capture SPIRV-Cross. Il resterait borné par le nombre de lots fixé par le CPU.
- **Indirect command buffers Metal.** Leur `maxCommandCount` est fixé par le CPU. Leurs barrières de rendu, disponibles à partir d'Apple9, n'autorisent pas non plus fragment→vertex.
- **Lecture CPU avant soumission.** Incorrecte, pour l'ordre des commandes et les sémaphores.
- **Retenu.** Capacité bornée réservée avant soumission, admission GPU tout-ou-rien, puis planification et exécution GPU exactes. Le scratch est réutilisé d'un dessin à l'autre grâce à une frontière d'encodeur, et reste suivi par Metal (`newBufferWithLength` hors tas ; seul `MVKVisibilityBuffer` est non suivi).

## 4. Contrat implémenté

1. **Enregistrement.** Chaque commande indirecte PerVertex non vide réserve, avant soumission et par passe multiview, une capacité R de records physiques (instances × vues × sommets). R est la valeur de `MVK_PERVERTEX_INDIRECT_RECORD_CAPACITY` (défaut 2²⁰), ramenée aux limites de taille de tampon du chemin direct. La réservation contient capture, occurrences, triplets, coins, indices collectés en `uint32`, scratch restart si le pipeline peut redémarrer (restart statique ou dynamique), et un plan partagé. Les arguments ne sont jamais lus sur le CPU. La réservation reste dans la transaction de soumission existante et la prérecharge (prefill).
2. **Admission GPU.** Avant l'exécution du moindre dessin de la commande, un noyau lit `Count` et tous les arguments. Il vérifie `sommets × instances × vues ≤ R` en arithmétique 64 bits sans débordement, ainsi que la plage d'indices contre la liaison clippée à l'allocation Metal. Les échecs sont accumulés par OR atomique dans un mot de statut.
3. **Exécution.** Si la commande est admise, chaque dessin `i < min(Count, maxDrawCount)` non vide est planifié sur GPU :
   - arguments de capture, région stage-in, `captureParams`, tables de replay ;
   - pour un dessin indexé, collecte des indices à partir de `firstIndex`, puis assemblage restart s'il est actif.

   La capture et le replay indirects sont ensuite exacts. `DrawID = i`. `firstVertex`, `vertexOffset` et `firstInstance` passent tels quels à Metal : aucun découpage.
4. **Échec.** Si un dessin, même le second seul, dépasse R ou lit hors du tampon d'index, **la commande entière ne fait rien** : aucun effet de bord de capture, aucun pixel. Quand tous les `MTLCommandBuffer` de la soumission ont terminé, `finish()` lit les statuts avant de signaler la fence de cette soumission et les sémaphores émulés signalés dans `finish()`. Il appelle alors `markLost()`, indépendamment de `resumeLostDevice`, et `vkWaitForFences` renvoie `VK_ERROR_DEVICE_LOST`. Les sémaphores natifs sont encodés sur le GPU et peuvent être signalés avant cette lecture CPU ; leur attente n'est pas couverte par cette garantie. Ce contrat ne dépend pas de l'ordre des gestionnaires de complétion, que la documentation Apple ne précise pas.

   **Portée exacte.** Il n'y a pas de travail partiel de la commande fautive. En revanche, les commandes antérieures et les commandes ultérieures s'exécutent (par exemple la copie de relecture du test). « Aucun travail partiel » ne vaut donc pas à l'échelle de la soumission.

## 5. Implémentation

**Production :**

- `MVKCmdDraw.mm` : `encodePerVertexIndirect`. Par dessin, une passe compute d'admission et de plan, puis restart ou tables et collecte, capture compute s'il est indexé, redémarrage de la passe de rendu, capture de rendu s'il est non indexé, barrière vertex→vertex|fragment, replay indirect. Les `setContent` réservent au lieu de refuser.
- `MVKCommandBuffer.*` : `recordPerVertexIndirectDraw`, rétention des pipelines d'aide avant soumission.
- `MVKQueue.*` : `reportPerVertexIndirectFailures` dans `finish()`.
- `MVKCommandPipelineStateFactoryShaderSource.h` : noyau `perVertexIndirect`. Il compile en MSL 2.4 et 3.1 via le compilateur d'exécution (`build/indirect-gpu/msl-check/`).
- Fichiers annexes :
  - `MVKCommandEncodingPool.*` et `MVKCommandResourceFactory.*` : pipeline d'aide ;
  - `MVKPerVertexScratch.h` : `buffers[7]` porte le plan et le statut ;
  - `MVKPerVertexReplay.h` : nombre d'étapes de scan du restart.

**Restart.** `perVertexRestart` est réutilisé sans modification :

- ses paramètres viennent de blocs de 256 octets écrits par le GPU ;
- le nombre d'étapes de scan est fixe (⌈log₂ R⌉) : les étapes surnuméraires ne font que copier, donc la parité reste connue du CPU ;
- le marqueur `0xFF`/`0xFFFF` est converti en `0xFFFFFFFF` lors de la collecte.

**Tests** (nouveaux fichiers, © Jean-Philippe Meunier) :

- `PerVertexIndirectGPUTests.cpp` ;
- `PerVertexIndirectKernelTests.cpp` ;
- `pervertex-indirect.{vert,frag}`, `pervertex-indirect-args.comp` ;
- `build-pervertex-test-library.sh`, `run-pervertex-indirect-gpu-tests.sh`, `run-pervertex-indirect-kernel-tests.sh`.

Tests mis à jour : `PerVertexIndirectTests.mm` et son script (la réservation remplace le refus), `PerVertexHelperPreflightTests.mm` et son script.

## 6. Preuves

### Matrice GPU finale (`build/indirect-gpu/matrix-final/`)

Bibliothèque `e404abe4…`. Fichiers : `matrix.log`, `results.csv`, `runs/*.log`, images `.rgba` indirectes et de référence, `INPUTS.sha256`, `EVIDENCE.sha256`.

**Principe de chaque cas :**

- Le tampon d'arguments, de compte et d'indices est **host-visible et mis à zéro par l'hôte** avant chaque soumission.
- Il est écrit dans le même command buffer par `vkCmdUpdateBuffer`, `vkCmdCopyBuffer` ou un compute shader, suivi d'une barrière vers `INDIRECT_COMMAND_READ|INDEX_READ`.
- Une lecture CPU prématurée verrait donc un dessin vide.

**Oracles :**

- image **plein cadre comparée octet par octet** aux dessins directs PerVertex de mêmes paramètres ; le shader de référence reçoit `DrawID` par push constant ;
- pour un dessin unique en liste de triangles, points intérieurs contre un oracle CPU indépendant ;
- SSBO `atomicAdd` par invocation, avec le multiensemble exact `(gl_VertexIndex, gl_InstanceIndex, gl_DrawID | gl_BaseInstance<<16, gl_BaseVertex)` ;
- écriture magenta antérieure préservée ;
- validation Metal API et GPU.

**Conditions d'échec d'un cas :**

- un message de validation ou « execution failed » ;
- pour une perte attendue, l'absence du message d'admission précis (« exceeds the reserved capture capacity » ou « reads indices beyond ») : une faute GPU ne peut donc pas passer pour un refus ;
- pour les autres cas, la présence de ce message.

**Fonctions activées :** `drawIndirectFirstInstance`, `multiDrawIndirect`, `shaderDrawParameters`, `vertexPipelineStoresAndAtomics`, `indexTypeUint8`, `extendedDynamicState2`.

| Groupe | Cas | Résultat |
| --- | --- | --- |
| Décisif | 4 formes × producteurs update/copy/compute × u8/u16/u32 pour l'indexé. `maxDrawCount=2`, compte GPU 1 (le second dessin est valide mais ignoré), 2 instances, `firstIndex=2`, `vertexOffset=±3`, `firstVertex=4`, `firstInstance=2` | 24/24, 12 invocations exactes |
| Zéro, deux, répétition | compte GPU 0 ou 0 instance ; deux dessins superposés et mélangés (Count 7 limité à 2, DrawID 0/1, ordre visible) ; un même command buffer soumis 3 fois avec arguments GPU changés | 12/12 |
| Capacité | R=12 : décisif et deux dessins passent (capacité par dessin). R=11 : décisif, et second dessin seul en dépassement → `wait=-4`, 0 invocation, 0 pixel, magenta préservé. `instanceCount=UINT32_MAX` : refus immédiat. `firstIndex=100000` : refus | 22/22 |
| Restart | strip avec marqueur u8/u16/u32, deux dessins, restart dynamique activé (14 invocations) ou désactivé (16), R=16 exact et R=15 en dépassement | 16/16 |
| Topologies | point, ligne, bande de lignes, bande et éventail de triangles × 4 formes, plus deux dessins en Count, avec le premier sommet provoquant | 25/25 |
| Stress | 2 dessins × 20 000 instances superposées et mélangées ; le dessin 1 réécrit, avec d'autres valeurs, le scratch lu par le replay du dessin 0 ; 240 000 invocations exactes | 4/4 |
| Prefill | modes 1 (différé) et 2 (immédiat) × 4 formes, plus restart | 10/10 |
| Négatifs | fragment aux coins permutés : 2976 octets différents, exit 2 attendu. Bibliothèque `d608d84c` : `vkEndCommandBuffer=-8`, exit 1 attendu | 8/8 |

### Tests hôte (`build/indirect-gpu/host-final/`, ASan/UBSan)

`indirect-kernel` exécute sur l'hôte les **noyaux MSL de production** `perVertexIndirect` et `perVertexRestart`, compilés en C++ (90 074 vérifications). Il couvre :

- tables GPU identiques à `mvkPopulatePerVertexReplay`, pour les 6 topologies, les deux modes de sommet provoquant (dont **dernier**, inaccessible sur GPU car `provokingVertexLast` exige l'API privée Metal), coins, vues, formes indexée et non indexée ;
- bornes d'admission, y compris des produits 64 bits sans débordement ;
- limitation du Count ;
- collectes pour 3 largeurs d'index ;
- blocs restart à nombre d'étapes fixe, identiques au restart direct ;
- mutation « provoking » : échoue (exit 1).

| Test | Résultat |
| --- | --- |
| indirect | 182 vérifications ; les deux mutations de réservation échouent |
| helper-preflight | passe |
| scratch, draw-size, restart (74 136 motifs), topology, prefill, memoryless | passent |

**Défaut préexistant, non causé par cette branche :** `run-pervertex-multiview-scratch-tests.sh` et `run-pervertex-multiview-draw-tests.sh` échouent **déjà à `d608d84c`** (doubles CPU non mis à jour : `getDynamicStateFlags`, `widenUint8Pipeline`). Preuve dans `build/indirect-gpu/host-baseline/`.

### Contrôles r12 (`build/indirect-gpu/r12-controls-final/`)

Script `build/indirect-gpu/run-r12-controls.sh`. Les fixtures r12 d'origine ont été recompilées sur la bibliothèque `e404abe4…`. Les sorties sont dans `CONTROLS.txt` et `EVIDENCE.sha256`.

| Contrôle | Relectures |
| --- | --- |
| `ordinary-indirect`, `ordinary-indexed-indirect`, `ordinary-indirect-count`, `ordinary-indexed-indirect-count` | identiques à `r12-persistent/readback-*.rgba` |
| PerVertex directs `direct`, `u16`, `u32`, `negative` | identiques aux relectures d'origine |

Tous les cas sortent avec le code 0 et la validation active.

## 7. Limites

- **Matériel.** M4 Pro, macOS 27.2 uniquement. M1/M3, les GPU Intel ou AMD et Apple10 ne sont pas testés. Les offsets de tampons constants sont alignés sur 256 octets pour les familles Mac.
- **Capacité.** C'est un **budget de prototype** (variable d'environnement), pas une borne générale. Mémoire par commande et par soumission, avec R=2²⁰, en liste de triangles indexée et avec un stride de 32 : environ 48 Mio, environ 84 Mio avec restart. Les bandes et éventails triplent les tables. Réduction possible, non implémentée : partager un seul scratch indirect par command buffer, ce qui est sûr puisque chaque dessin est séparé par une frontière d'encodeur.
- **Coût.** Un redémarrage de passe de rendu par entrée de `maxDrawCount`, y compris au-delà de `Count`. Le coût est proportionnel à `maxDrawCount`. Aucune mesure de performance n'a été faite.
- **Refus explicites à l'enregistrement :** liaisons de sommets à diviseur zéro ; attachements memoryless ou résolutions qui ne survivent pas au redémarrage, comme pour l'indexé direct ; multiview à plusieurs vues (garde fermée ; le code multiplie les instances par les vues, mais ce chemin n'est pas testé).
- **Sommet provoquant « dernier ».** Couvert uniquement par le test hôte du noyau, pas sur GPU.
- **Hazards entre dessins.** L'absence de hazard écriture-après-lecture repose sur le suivi Metal et sur la frontière d'encodeur. Le cas de stress l'éprouve fortement, sans le prouver formellement.
- **Non testés :** sémaphores et soumissions distinctes produisant les arguments, command buffers secondaires, couches de validation Khronos (indisponibles). Brume n'a pas été utilisé.

## 8. Plus petit changement vers un support non borné

La continuation est la seule voie compatible avec le chemin portable actuel :

1. Au premier dessin indirect PerVertex, l'encodage termine le `MTLCommandBuffer` A, qui se termine par l'admission et la planification. Il réserve la position de B par `[B enqueue]`, puis le valide.
2. Un fil d'encodage attend A de façon asynchrone. Ce n'est jamais le fil de `vkQueueSubmit` : attendre des sémaphores signalés plus tard par l'hôte provoquerait un interblocage.
3. Ce fil lit les besoins exacts, encode les dessins par morceaux dans le scratch borné déjà réservé (frontière d'encodeur entre morceaux), encode le reste du command buffer Vulkan dans B, puis signale fences et sémaphores sur B.

Conditions :

- découpage des soumissions dans `MVKQueueCommandBufferSubmission` ;
- prefill désactivé pour ces command buffers ;
- découpage d'un dessin par plages d'instances : il suppose que SPIRV-Cross accepte une base de record et une base d'instance explicites, pour préserver `gl_BaseInstance` et les diviseurs.

Coût : un aller-retour GPU→CPU par commande concernée.

L'alternative est un chemin mesh (Metal 3) sans mémoire intermédiaire, qui exige une transformation VS→mesh et la preuve de l'ordre des primitives. Ni l'une ni l'autre n'est implémentée ici.

## 9. Éléments pour le plan (étape 4)

Proposition de texte :

> **Dessins indirects, étape 4 — prototype borné validé sur M4.** Branche `claude/pervertex-indirect-gpu`, `5d6d8508`..`b5a1caec` (base `d608d84c`), bibliothèque de test `e404abe4`. Capacité R réservée avant soumission ; admission GPU tout-ou-rien de chaque commande (compte, arguments, plage d'indices) ; planification, tables, collecte d'indices et restart sur GPU ; capture et replay indirects exacts. Au-delà de R, la commande ne fait rien et le périphérique est perdu dans `finish()`, avant la fence de la soumission. Matrice M4 121/121 sous validation Metal API/GPU : quatre formes, trois producteurs GPU, compte nul, répétitions, bornes, restart statique et dynamique, six topologies, stress. Test hôte des noyaux de production pour les deux modes de sommet provoquant. Contrôles r12 identiques. Dans le chemin capture/replay étudié, un nombre d'encodeurs fixé par le CPU et une réservation finie ne couvrent pas tous les arguments légaux. Une continuation ou un autre chemin reste à étudier pour lever cette limite. Restent : fusion avec le WIP TES (`buffers[7..11]`), budget R configurable et scratch partagé par command buffer, diviseur zéro, multiview, M1/M3, performances, revue Astra. Garde publique fermée.

## 10. Reproduction

```bash
cd /Users/carbo/Documents/Code/external/pervertex-upstream-20260926/MoltenVK-indirect-gpu
mkdir -p External
for d in SPIRV-Tools Volk Vulkan-Headers Vulkan-Tools cereal; do ln -sfn ../../MoltenVK/External/$d External/$d; done
ln -sfn ../../SPIRV-Cross-indirect-gpu External/SPIRV-Cross
bash MoltenVK/Tests/build-pervertex-test-library.sh d608d84c build/indirect-gpu/lib-before
bash MoltenVK/Tests/build-pervertex-test-library.sh b5a1caec build/indirect-gpu/lib-final
bash MoltenVK/Tests/run-pervertex-indirect-gpu-tests.sh build/indirect-gpu/lib-final/arm64/MoltenVK/libMoltenVK.1.4.3.dylib build/indirect-gpu/lib-before/arm64/MoltenVK/libMoltenVK.1.4.3.dylib build/indirect-gpu/matrix-final
bash build/indirect-gpu/run-r12-controls.sh build/indirect-gpu/lib-final/arm64/MoltenVK/libMoltenVK.1.4.3.dylib build/indirect-gpu/r12-controls-final
bash MoltenVK/Tests/run-pervertex-indirect-kernel-tests.sh build/indirect-gpu/host-final/indirect-kernel
MVK_INDIRECT_KERNEL_MUTATION=provoking bash MoltenVK/Tests/run-pervertex-indirect-kernel-tests.sh build/indirect-gpu/host-final/negative-kernel
bash MoltenVK/Tests/run-pervertex-indirect-tests.sh build/indirect-gpu/host-final/indirect
MVK_INDIRECT_REMOVE_GUARD=MVKCmdDrawIndexedIndirect bash MoltenVK/Tests/run-pervertex-indirect-tests.sh build/indirect-gpu/host-final/negative
bash MoltenVK/Tests/run-pervertex-helper-preflight-tests.sh build/indirect-gpu/host-final/helper-preflight
```

- Les deux commandes à mutation (`MVK_INDIRECT_KERNEL_MUTATION`, `MVK_INDIRECT_REMOVE_GUARD`) doivent échouer (exit 1).
- La matrice GPU dure environ 13 s et s'arrête au premier écart.
- `run-r12-controls.sh` échoue s'il trouve un code de sortie non nul, une validation absente ou une relecture différente.
