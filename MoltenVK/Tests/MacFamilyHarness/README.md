# Harnais Mac r13 : essais M1 et M3

Ce bundle hors ligne fait deux choses sur un Mac Apple Silicon :
- il relève les capacités Vulkan et Metal que ce Mac expose réellement avec la bibliothèque MoltenVK fournie ;
- il lance un smoke borné des chemins PerVertexKHR direct et indexé, indirect, TES et mesh, **seulement quand ces capacités les admettent**.

Aucune capacité n'est déduite du nom du Mac ou du GPU : ce nom est seulement noté dans le rapport.

**Pas d'annonce de prise en charge générique.**
- Les résultats décrivent ce Mac, cette version de macOS et cette bibliothèque de test.
- La bibliothèque est une bibliothèque **de test** (Debug, arm64) : les extensions barycentrique et mesh ne s'y ouvrent que par des adaptateurs de test, que les fixtures appellent. Sans eux, elles restent fermées ; le cas `mesh-gate` le vérifie.
- La validation utilisée est la validation Metal (API et shaders), pas les couches de validation Khronos, qui ne sont pas fournies.

L'identité de la bibliothèque est dans `PROVENANCE.txt` : commits MoltenVK et SPIRV-Cross, empreinte SHA-256, options de compilation.

## Prérequis

- **Machine :** Mac Apple Silicon, Terminal **natif arm64** (pas sous Rosetta).
- **Système :** seulement les outils de macOS : Bash, Perl, `shasum`, `tar`, `codesign`. Ni Xcode, ni SDK Vulkan, ni Homebrew, ni réseau.
- **Version de macOS :** la bibliothèque et les exécutables visent macOS 11.0 au minimum. C'est un plancher de déploiement, **pas une preuve** que ce macOS fournit les capacités voulues : la sonde les mesure. Le mesh demande Metal 3 (macOS 13 ou plus).
- **Charge :** une machine au repos. Ne lancez pas deux copies en même temps (un verrou `.run-lock` l'empêche).

## Commandes

Dans le répertoire où se trouvent l'archive et son fichier `.sha256` :

```bash
shasum -a 256 -c mac-family-harness-r13.tar.gz.sha256
tar -xzf mac-family-harness-r13.tar.gz
cd mac-family-harness-r13
./run.sh --verify-only
./run.sh --smoke
```

Lisez le résumé de `--verify-only` avant de lancer `--smoke`.

Si macOS refuse d'exécuter les programmes parce que l'archive est arrivée par AirDrop ou par un navigateur, retirez la quarantaine du répertoire extrait, puis recommencez :

```bash
xattr -dr com.apple.quarantine .
```

## Ce que font les deux modes

**`--verify-only` ne soumet aucun travail GPU.** Dans l'ordre :
1. il vérifie `SHA256SUMS`, l'alias `lib/libMoltenVK.1.dylib`, l'empreinte de la bibliothèque et les signatures ad hoc ;
2. il lance la sonde `bin/probe` : celle-ci crée un périphérique Metal et une instance Vulkan, sans rien soumettre, et écrit `capabilities.txt` ;
3. il affiche le **plan du smoke** : pour chaque cas, `RUN`, ou `SKIP` avec la liste des capacités manquantes.

**`--smoke`** refait tout cela, puis lance un par un les cas admis :

| Cas | Chemin | Exige |
| --- | --- | --- |
| `mesh-gate` | extensions mesh et barycentrique fermées sans adaptateur ; aucun travail GPU | instance Vulkan |
| `pervertex-direct-indirect` | draws PerVertexKHR **directs**, validés contre un oracle CPU, puis `vkCmdDrawIndirect` comparé octet par octet | barycentrique, `VK_KHR_draw_indirect_count`, `shaderDrawParameters`, `drawIndirectFirstInstance`, `multiDrawIndirect`, `vertexPipelineStoresAndAtomics` |
| `pervertex-indexed-indirect` | draws PerVertexKHR **indexés**, puis `vkCmdDrawIndexedIndirect` | idem |
| `pervertex-swap-negative` | témoin : fragment aux coins échangés, **doit** échouer (sortie 2, pixels différents) | idem, et le cas direct réussi |
| `tes-ordinary-direct`, `tes-ordinary-indexed` | tessellation ordinaire à niveaux float32 | `tessellationShader` et stockages VS/FS, `multiDrawIndirect`, `shaderDrawParameters` |
| `tes-pervertex-f1` | topologie TES PerVertex produite sur GPU | idem, et barycentrique |
| `tes-scratch-limit-prefill`, `tes-scratch-limit-async` | draw de tessellation au-delà de la limite Metal : **doit être refusé** à l'enregistrement, sans travail GPU (le second seulement si le premier réussit) | idem |
| `mesh-draw`, `mesh-pervertex`, `mesh-form-mixed` | pipeline mesh, PerVertexKHR sur mesh, formes exactes mélangées | `meshShader` (via l'adaptateur, donc Metal 3), barycentrique, `shaderDrawParameters`, `bufferDeviceAddress` |
| `continuation-legal-sync`, `continuation-restart-async` | dessin indirect légal dont les arguments sont produits sur une autre file, libérée par un signal hôte tardif ; soumission dépendante C et `vkQueueWaitIdle` : le dessin doit rendre, C doit réussir | les capacités indirectes et `timelineSemaphore` |
| `continuation-huge-loss`, `continuation-index-oob-loss` | dessin indirect non représentable, ou lisant des indices hors du buffer : le périphérique doit être perdu, et C ne doit jamais réussir | idem |
| `tes-level4-loss` | dessin TES PerVertex à niveau 4, sans topologie prouvée, avant un dessin indirect : perte avant le dessin indirect, C jamais réussie | idem, et les capacités TES |
| `mesh-grid-limit` | `vkCmdDrawMeshTasksEXT(2048, 2048, 1)` : au-delà de la grille que Metal exécute, **doit être refusé** à l'enregistrement | capacités mesh |
| `mesh-limits` | mesure, en Metal seul, des limites mesh que Vulkan exige (groupes, grille, sorties, mémoire, couches) ; le résultat est une donnée, pas un verdict | Metal 3 |

Tous les cas exigent aussi que la validation Metal soit active : la sonde vérifie qu'elle s'annonce.

**Bornes :**
- un seul processus de test à la fois ;
- 40 secondes au plus par cas (240 pour `mesh-limits`), plus 1 seconde d'arrêt forcé ;
- 19 cas, sans matrice automatique ;
- le premier `FAIL` arrête tous les cas GPU suivants (`NOT-RUN`).

Ces bornes ne peuvent pas rattraper un blocage du système ou du GPU.

## Lire le résultat

Chaque cas se termine par l'un de ces états :
- `PASS` ;
- `FAIL` : sortie inattendue, dépassement de délai, erreur de validation Metal, validation non annoncée, ou autre bibliothèque MoltenVK chargée ;
- `REFUSED` : MoltenVK a refusé (`VK_ERROR_FEATURE_NOT_PRESENT`) une forme que ce cas devait rendre ;
- `SKIPPED` : une capacité manque, et le résumé liste les clés absentes ;
- `NOT-RUN` : arrêté par un `FAIL` précédent.

Codes de sortie de `run.sh` :

| Code | Signification |
| --- | --- |
| 0 | tout exécuté a réussi, rien d'ignoré ni de refusé |
| 3 | aucun échec, mais des cas refusés ou ignorés |
| 1 | au moins un échec, ou une vérification échouée |
| 64 | mauvaise commande |
| 75 | un autre lancement est actif, ou un `.run-lock` est resté après un arrêt brutal. Vérifiez qu'aucun programme de `bin/` ne tourne avant de supprimer ce répertoire. |

## À renvoyer

Chaque lancement écrit `reports/<date UTC>-<PID>/` et l'archive `reports/<date UTC>-<PID>.tar.gz`. Renvoyez **toutes** ces archives, y compris en cas d'échec.

Elles contiennent :
- l'hôte, les capacités et le plan ;
- les journaux de chaque cas ;
- les images brutes et le résumé ;
- leurs empreintes.

## Contenu

- `lib/` : la bibliothèque de test, avec sa signature d'éditeur de liens d'origine (ne pas la re-signer).
- `bin/` : la sonde et les trois fixtures, signées ad hoc, liées à `@executable_path/../lib`, et la sonde Metal `mesh-limits`, qui ne charge pas MoltenVK.
- `shaders/` : le SPIR-V.
- `source/` : les sources de la sonde, du runner, des fixtures et des shaders, pour référence.
- `PROVENANCE.txt`, `SHA256SUMS` : identité et empreintes. Ces sommes détectent une corruption, mais n'authentifient pas l'éditeur.
