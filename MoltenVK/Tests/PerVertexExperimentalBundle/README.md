# Candidat PerVertexKHR expérimental : bundle de qualification

Ce bundle hors ligne qualifie, sur un Mac Apple Silicon, **un candidat expérimental** de MoltenVK pour
`VK_KHR_fragment_shader_barycentric` : le chemin portable capture puis rejeu, étages vertex et fragment, dans un périmètre
minimal. **Ce n'est pas une extension publique conforme** : sans activation explicite, l'extension reste fermée.

Le périmètre annoncé reste **« à qualifier »** jusqu'aux passages de cette configuration (admission TES OFF, adaptateur
ON). Les résultats de référence viennent de bibliothèques avec admission ON : ce sont des attendus, pas des preuves
acquises. Voir `source/` et la définition du candidat dans le fork (`MoltenVK/Tests/PerVertexExperimental-CANDIDATE.md`).

## Identités

Trois identités distinctes, toutes dans `PROVENANCE.txt` :
- **sources** : `source_commit`, SHA complet du commit du fork ; son runtime est celui de `runtime_base` (`fb3970cc`) ;
- **bundle** : `bundle_revision` (nom), et l'empreinte de `SHA256SUMS`, qui couvre chaque fichier du bundle ;
- **bibliothèque** : `library_sha256`. À l'exécution, `run.sh` vérifie aussi la **bibliothèque réellement chargée** :
  dyld (`DYLD_PRINT_LIBRARIES`) doit nommer le seul `lib/libMoltenVK.1.4.3.dylib` du bundle, dont l'empreinte est
  recalculée, et la révision que la bibliothèque chargée publie (4 premiers octets de `pipelineCacheUUID`) doit être
  celle de `source_commit`.

Configuration : Debug arm64, admission TES OFF, adaptateur de test lié, `MVK_USE_METAL_PRIVATE_API` OFF, cible macOS 11.0.
Activation : l'application appelle `mvkEnableTESFixtureDevice(VkPhysicalDevice)`, qui n'ouvre que
`VK_KHR_fragment_shader_barycentric`. La bibliothèque exporte aussi des crochets de test : ce n'est pas une bibliothèque de
distribution.

## Prérequis

- **Machine :** Mac Apple Silicon, Terminal **natif arm64** (pas sous Rosetta).
- **Système :** macOS 11.0 au moins (plancher de déploiement de tous les binaires, pas une preuve de capacité).
- **Outils :** seulement ceux de macOS : Bash, Perl, `shasum`, `tar`, `codesign`. Ni Xcode, ni Homebrew, ni SDK Vulkan, ni
  réseau.
- **Disque :** au moins 8 Gio libres pendant la CTS ; la course s'arrête en dessous.
- **Charge :** machine au repos, une seule course à la fois (verrou `.run-lock`).

## Commandes

Dans le répertoire de l'archive et de son `.sha256` :

```bash
shasum -a 256 -c pervertex-experimental-c3.tar.gz.sha256
tar -xzf pervertex-experimental-c3.tar.gz
cd pervertex-experimental-c3
./run.sh --verify-only
./run.sh --qualify
```

Si macOS refuse d'exécuter les programmes parce que l'archive est arrivée par AirDrop ou un navigateur, retirez la
quarantaine du répertoire extrait, puis recommencez : `xattr -dr com.apple.quarantine .`

## Les deux modes

**`--verify-only`** ne soumet aucun travail GPU :
1. `SHA256SUMS`, alias `lib/libMoltenVK.1.dylib`, empreinte de la bibliothèque, signatures ;
2. **G, identité** : la sonde `bin/probe` crée un périphérique Metal et une instance Vulkan, sans rien soumettre. Elle
   relève la révision publiée, la bibliothèque chargée, et la garde au niveau de l'API : sans activation,
   `fragmentShaderBarycentric` doit valoir 0 ; après `mvkEnableTESFixtureDevice`, 1.

**`--qualify`** refait tout cela, puis la liste fermée, dans cet ordre, sous validation Metal (API et GPU) :

| Étape | Test | Attendu | Borne |
| --- | --- | --- | --- |
| B | Oracle de topologie dynamique : 14 cas (triangles et lignes ; direct et indexé ; fragments `pervertex`, `ordinary`, et pour les triangles `weights`, `weights-w`, `weights-w-noperspective`) | `PASS` chacun | 60 s par cas |
| C | Séparation capture/rejeu, attachements memoryless (profondeur, stencil) | `REFUSED` chacun (sortie 4) | 60 s par cas |
| D | CTS `fragment_shading_barycentric`, périmètre minimal, 1 201 cas, candidat activé par le shim CTS | `Pass` chacun | paquets de 200, 1 800 s par paquet |
| F | **Bibliothèque candidate sans activation** : la liste D, `deqp-vk` recevant directement la bibliothèque | `NotSupported` chacun | idem |
| E | CTS ordinaire, topologies et éventails, 562 cas, par le shim CTS, **en dernier** | statut de chaque cas identique à la référence M4 | idem |

Chaque étape compare **chaque cas, par son nom et son statut**, au fichier de `expected/` : un cas absent, en trop ou de
statut différent est une divergence (`compare-<étape>.txt`). Les totaux sont affichés mais ne décident rien. Un saut ou un
`NotSupported` là où `Pass` est attendu est une absence de preuve, donc une divergence. Chaque journal doit aussi annoncer
la validation Metal, ne contenir aucune erreur de validation ou d'exécution, et ne charger que la bibliothèque du bundle.
**La première divergence ou le premier échec arrête toutes les étapes suivantes** (`NOT-RUN`).

E passe en dernier parce que ses statuts attendus ont été mesurés sur M4 et dépendent le plus du Mac : ses 5 `Fail`
(`*_bind_unused_ms`) supposent l'adaptateur mesh ouvert, donc Metal 3 (macOS 13 ou plus). Une divergence de E sur un autre
Mac est une donnée à attribuer (capacité ou défaut) avant tout correctif ; elle ne remet pas en cause les étapes déjà
passées.

**F n'est pas un build de production.** Dans F, l'adaptateur reste lié à la bibliothèque candidate mais n'est jamais
appelé. Un build de production sans adaptateur (`test_device OFF`) n'est ni contenu ni testé par ce bundle.

Le shim CTS (`lib/libpervertex-cts-shim.dylib`, source `source/AdapterShim.c`) est celui des courses de référence : il
ouvre l'adaptateur barycentrique et l'adaptateur mesh. Aucun cas de D, E ou F n'est un cas mesh ; l'activation
documentée du candidat pour une application reste `mvkEnableTESFixtureDevice` seul.

Les refus de C documentent une limite expérimentale ; ils ne démontrent pas la légalité Vulkan de ce refus.

## Codes de sortie

| Code | Signification |
| --- | --- |
| 0 | toutes les étapes identiques à leurs attendus, cas par cas |
| 1 | un échec, une divergence ou une vérification échouée |
| 64 | mauvaise commande |
| 75 | une autre course est active, ou un `.run-lock` est resté après un arrêt brutal (vérifiez qu'aucun programme de `bin/` ou `cts/` ne tourne avant de supprimer ce répertoire) |

## À renvoyer

Chaque lancement écrit `reports/<date UTC>-<PID>/` et `reports/<date UTC>-<PID>.tar.gz`. Renvoyez **toutes** ces archives,
y compris en cas d'échec : hôte, identité, journaux, résultats cas par cas, comparaisons et empreintes.

## Contenu

- `lib/` : la bibliothèque candidate (signature d'éditeur de liens d'origine, ne pas la re-signer) et le shim CTS.
- `bin/` : la sonde et les programmes B et C, liés à `@executable_path/../lib`, signés ad hoc.
- `cts/` : `deqp-vk` (VK-GL-CTS `vulkan-cts-1.4.6.2`, Release arm64 pour macOS 11.0, avec la libpng de la CTS) et ses
  données.
- `shaders/` : le SPIR-V de B et C.
- `lists/` : les listes exactes D et E. `inputs/` : leur entrée non versionnée (`barycentric-runnable.txt`,
  `barycentric.txt`, `SOURCE.txt`), les empreintes de `build/cts-lists`, et les résultats de référence de E.
- `expected/` : les attendus cas par cas de B à F.
- `source/` : les sources des programmes, du shim, des shaders, de la sélection D et de l'empaquetage.
- `licenses/` : MoltenVK, VK-GL-CTS, libpng.
- `PROVENANCE.txt`, `SHA256SUMS`. Ces sommes détectent une corruption ; elles n'authentifient pas l'éditeur.

Les suites hôte de la liste fermée (A) demandent un compilateur : elles tournent sur le Mac de construction, pas dans ce
bundle.
