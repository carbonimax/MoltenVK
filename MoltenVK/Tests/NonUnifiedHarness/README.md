# Kit de qualification R8 sans mémoire unifiée

Ce bundle hors ligne vérifie, sur un Mac **Intel avec GPU sans mémoire unifiée** (AMD ou eGPU), la partie de R8 qu'un Mac Apple Silicon ne peut pas exécuter. Il s'agit de l'inventaire de la perte de device pour la mémoire hôte importée.

Seul un GPU sans mémoire unifiée fait encoder à MoltenVK une synchronisation Metal, depuis `vkInvalidateMappedMemoryRanges` et `vkCopyImageToMemoryEXT`, sur une mémoire de type « managed ». Ailleurs, ces chemins ne s'exécutent jamais : un Mac Apple Silicon, ou un Intel à GPU intégré, ne qualifie rien.

## Ce qui est vérifié

Chaque cas tourne 3 fois, en soumission synchrone puis asynchrone, sous validation Metal (API et shaders) :

| Cas | `before` (première version de R8) | `no-admission` (témoin négatif) | `after` (R8 final) |
| --- | --- | --- | --- |
| `host-sync-progress-invalidate`, `-copy` : la file Metal est pleine, la synchronisation bloque en acquérant son command buffer, le device est perdu. Aucun encodage ne doit retenir le rapport de la perte | FAIL attendu | PASS attendu | PASS attendu |
| `host-sync-admission-invalidate`, `-copy` : l'acquisition ne rend son command buffer qu'après le début de la perte, puis la synchronisation est relancée après le rapport. Aucun commit Metal ne doit avoir lieu | FAIL attendu | FAIL attendu | PASS attendu |
| `free-imported-*` (5 cas) : `vkFreeMemory` d'une mémoire importée attend le travail admis avant la perte, et seulement lui | — | — | PASS attendu |

- `before` est la bibliothèque de `67dd59d4` : l'acquisition se fait dans l'encadrement, sans garde d'admission.
- `after` est celle de `d4110762`.
- `no-admission` est `d4110762` sans ses deux gardes d'admission (`source/no-admission.patch`) : il montre que le cas « admission » détecte bien leur absence.

Le verdict final est **QUALIFIED** seulement si chaque exécution donne le résultat attendu, et si **aucune** n'est sautée (`SKIP`). Un `SKIP` veut dire que ce Mac ne peut pas exécuter le chemin : mémoire unifiée, pas de type « managed », ou pas de `VK_EXT_host_image_copy` pour les cas `-copy`.

## Prérequis

- **Machine :** Mac Intel avec GPU discret ou eGPU, Terminal **x86_64 natif**. Un Mac Intel qui n'a qu'un GPU intégré a la mémoire unifiée : il sautera les cas.
- **Système :** seulement les outils de macOS (Bash, Perl, `shasum`, `tar`). Ni Xcode, ni SDK Vulkan, ni Homebrew, ni réseau. macOS 11.0 au minimum.
- **Durée :** quelques minutes, 102 exécutions bornées à 60 s chacune.

## Lancer

```bash
tar -xzf non-unified-harness-r1.tar.gz
cd non-unified-harness-r1
bash run.sh
```

Si macOS bloque les binaires téléchargés, lever la quarantaine du dossier, puis relancer :

```bash
xattr -dr com.apple.quarantine non-unified-harness-r1
```

À la fin, `run.sh` affiche `NON_UNIFIED QUALIFIED` ou `NON_UNIFIED NOT QUALIFIED`, avec la raison. **Renvoyer tout le dossier `results-…`** qu'il indique. Il contient :
- l'environnement (modèle, macOS, GPU) ;
- `results.csv` et chaque journal ;
- le verdict et `EVIDENCE.sha256`.

## Ce que ce kit ne prouve pas

- Il ne prouve rien sur Apple Silicon, où ces chemins ne s'exécutent pas.
- Il ne remplace ni les essais M1 et M3, ni iOS.
- Il ne rend pas la perte rapportée en temps fini : R6 reste fermé.
- Un passage sous Rosetta sur un Mac Apple Silicon vérifie seulement que le bundle s'exécute (`NON_UNIFIED_SMOKE=1`). Les cas y sont sautés, ce n'est pas une qualification.

L'identité des bibliothèques et de la source des tests est dans `PROVENANCE.txt` ; `SHA256SUMS` couvre tout le bundle et `run.sh` le vérifie avant de commencer.
