# PerVertex Vulkan : essai sur iPhone et iPad

App iOS (iOS 16.0 minimum) qui exécute, **sur l'appareil**, les fixtures Vulkan utilisées sur Mac :
- le pilote PerVertexKHR indirect ;
- le pilote mesh.

Elle les fait tourner contre la bibliothèque MoltenVK **de test**, construite pour iOS et embarquée dans l'app.

**Ce qui est testé.** Chaque résultat vient de ce que la fixture a vérifié sur ce GPU. Aucune capacité n'est déduite du nom de l'appareil : le rapport note les familles GPU mesurées.

**Garde publique.** La bibliothèque publique ferme `VK_KHR_fragment_shader_barycentric` et `VK_EXT_mesh_shader` sur toutes les plateformes. L'app les ouvre par l'adaptateur de test, sauf pour le premier cas, qui vérifie qu'ils restent fermés sans adaptateur.

## Cas

| Cas | Ce qui est vérifié |
| --- | --- |
| `public-gate-closed` | extensions barycentrique et mesh fermées sans adaptateur |
| `pervertex-single-draw`, `-single-indexed`, `-decisive-draw-count`, `-restart-strip` | PerVertexKHR rendu à travers Vulkan. Dessins uniques comparés à un oracle CPU indépendant ; les autres, au rendu direct. |
| `pervertex-swap-negative` | témoin : coins permutés, **doit** échouer (sortie 2, pixels différents) |
| `portable-single-draw`, `portable-restart-strip`, `portable-swap-negative` | mêmes contrôles avec un fragment qui lit aussi `BaryCoordKHR` (sans effet sur la couleur), ce qui force la capture et le replay portables sur tous les GPU |
| `continuation-*` | arguments produits sur une autre file après un signal hôte tardif, soumission dépendante et `vkQueueWaitIdle`. Les dessins légaux rendent ; les dessins perdus perdent le périphérique, sans succès de la soumission dépendante. |
| `tes-after-indirect`, `tes-level4-loss` | TES PerVertex légal, et TES à niveau 4 qui doit perdre le périphérique |
| `mesh-draw`, `mesh-pervertex`, `mesh-form-mixed`, `mesh-grid-limit` | mesh par l'adaptateur (Metal 3), et refus d'une grille trop grande |

**Chemin PerVertexKHR sur l'appareil.** Les cas `pervertex-*` acceptent qu'un sommet soit ombré plusieurs fois, ce que Vulkan permet. Les cas `portable-*`, `continuation-*` et `tes-*` lisent aussi `BaryCoordKHR` : ils prennent la capture portable partout, et exigent le compte exact d'invocations.
- **Apple10 avec MSL 4.0** (iOS 26 ou plus) : les pipelines triangle prennent `vertex_value` natif. C'est le cas de l'iPhone 18 Pro.
- **Ailleurs :** capture puis replay. C'est le cas de l'iPhone 15 Pro et de l'iPad Pro M4 (Apple9).
- **Dans le rapport :** `device.expected_pervertex_path` indique le chemin que cette règle choisit. C'est une valeur déduite de la règle, pas observée.

**Configuration.** MoltenVK lit sa configuration une seule fois par processus. Chaque lancement couvre donc un seul mode de soumission : lancez l'app une fois en synchrone, puis une fois en asynchrone.

## Construire (Mac avec Xcode 27, XcodeGen, CMake, Ninja, glslang, SPIRV-Tools)

Depuis la racine de ce dépôt, sources commitées :

```bash
bash MoltenVK/Tests/PerVertexVulkanTrial/build-trial.sh build/ios-trial-device DEVELOPMENT_TEAM=<équipe> CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates
```

- Ajoutez les options `-authenticationKey…` de votre clé App Store Connect si Xcode n'a pas de compte actif.
- `TRIAL_PLATFORM=simulator` construit pour le simulateur. Le GPU du simulateur n'a ni coordonnées barycentriques ni mesh Metal 3 : la plupart des cas y sont ignorés. Seule la plomberie de l'app y est vérifiable.

## Lancer (appareil iOS 17 ou plus, déverrouillé, mode développeur actif)

Un lancement à la fois. D'abord avec la validation Metal, pour la correction, puis sans elle :

```bash
bash MoltenVK/Tests/PerVertexVulkanTrial/run-trial-device.sh build/ios-trial-device/DerivedData/Build/Products/Release-iphoneos/PerVertexVulkanTrial.app <UDID> build/ios-trial-runs/<appareil> sync validated
```

```bash
bash MoltenVK/Tests/PerVertexVulkanTrial/run-trial-device.sh build/ios-trial-device/DerivedData/Build/Products/Release-iphoneos/PerVertexVulkanTrial.app <UDID> build/ios-trial-runs/<appareil> async validated
```

**Ce que fait le script.**
1. Il installe l'app.
2. Il la lance sans débogueur, par `devicectl`, avec les variables de configuration et de validation.
3. Il attend au plus 15 minutes un nouveau `report.json`.
4. Il rapatrie ce run avec ses journaux et `SHA256SUMS`.

Il accepte `plain` à la place de `validated`.

**iOS 16 et plus ancien.** `devicectl` ne gère pas ces appareils. `run-trial-legacy-device.sh` prend les mêmes arguments et passe par libimobiledevice (Homebrew) :
- `ideviceinstaller` installe l'app ;
- `idevicedebug` la lance avec l'environnement, puis s'en détache ;
- `afcclient` rapatrie les runs.

Le lancement à distance exige l'image disque développeur de cette version, déjà montée sur l'appareil. Sans elle, `TRIAL_MANUAL_LAUNCH=1` attend qu'on touche l'icône. L'app tourne alors avec la configuration MoltenVK par défaut (soumission synchrone, sans pré-remplissage) et sans validation Metal : seul `sync plain` est possible.

**Lecture du rapport.** Chaque cas finit en `PASS`, `FAIL` ou `SKIPPED` (capacité absente, avec sa raison). Le rapport global vaut `PASS`, `FAIL` ou `INCOMPLETE`.

**Arrêt en cours de cas.** Si un cas arrête l'app, le `journal.txt` du run garde un `START` sans `END`. Le rapport du lancement suivant le liste sous `interrupted_previous_runs`.

## Ce qui a été vérifié

**Constructions.** Non signée pour l'appareil et le simulateur ; signée pour l'équipe personnelle. Le profil couvre l'iPhone 18 Pro, l'iPhone 15 Pro, l'iPad Pro M4 et l'iPad Pro 9,7″.

**Simulateur iOS 27.0.** Plomberie seulement : les cas s'exécutent et le rapport s'écrit.

**Appareils, le 28 septembre 2026, avec l'app construite depuis `a564af04`.** Chaque passage tourne sans débogueur ; la validation Metal est annoncée dans les passages « avec validation ».

| Appareil | Chemin PerVertexKHR | Synchrone, avec validation | Asynchrone, avec validation | Synchrone, sans validation |
| --- | --- | --- | --- | --- |
| iPhone 18 Pro (`iPhone19,2`, iOS 27.2, Apple10) | natif `vertex_value`, et portable pour `portable-*`, `continuation-*`, `tes-*` | 19/19 | 19/19 | 19/19 |
| iPhone 15 Pro (`iPhone16,1`, iOS 27.0, Apple9) | portable | 19/19 | 19/19 | 19/19 |
| iPad Pro 11″ M4 (`iPad16,3`, iPadOS 27.2, Apple9) | portable | 19/19 | 19/19 | 19/19 |
| iPad Pro 9,7″ (`iPad6,3`, iPadOS 16.7.16, Apple3) | aucun | non lancé | non lancé | 1 réussi, 18 ignorés |

**iPad Pro 9,7″.** L'app a été lancée à la main : aucune image disque développeur n'était montée. Seul `public-gate-closed` s'exécute, et réussit. Les 18 autres cas sont ignorés, faute de barycentriques Metal et de Metal 3 : ils s'arrêtent au choix du périphérique, avant tout travail GPU.

**Défauts trouvés par ces essais, et corrigés.**
- **Collision SPIRV-Cross.** Un fragment qui lit PerVertexKHR et `BaryCoordKHR` ne compilait pas : fausse collision de location privée. Corrigé par SPIRV-Cross `6af5a67f`, épinglé en `41a6c184`.
- **Replay non indexé vide, sous validation des shaders seulement.** Avant `a564af04`, la capture et le replay non indexés étaient séparés par une barrière dans la passe de rendu. Sous `MTL_SHADER_VALIDATION=1`, ces dessins ne rendaient rien, tout en rapportant un succès, sur l'iPhone 15 Pro, l'iPhone 18 Pro et l'iPad Pro M4. Sans validation, la même build (`b9165508`) passe 19/19 sur les trois. `a564af04` remplace la barrière par une frontière de passe de rendu, qui marche dans les deux cas mais coûte plus cher (voir ci-dessous).

**Non vérifié.**
- Sur l'iPad Pro 9,7″, les modes asynchrone et avec validation : ils demandent un lancement à distance.
- Tout autre iPhone ou iPad.

## Reproducteur Metal de la barrière

`TRIAL_EXTRA_ENVIRONMENT='"TRIAL_SUITE":"metal-barrier"'` fait tourner à l'app `PerVertexBarrierRepro` au lieu des cas Vulkan. C'est du Metal pur, sans MoltenVK, qui reproduit la capture et le replay d'avant `a564af04`. Chaque variante tourne 5 fois ; le tableau donne le nombre de fois où le replay a vu les enregistrements de la capture.

| GPU | Mode | Barrière (toutes variantes) | Frontière de passe | Sans ordre (témoin) |
| --- | --- | --- | --- | --- |
| iPhone 15 Pro, iPhone 18 Pro, iPad Pro M4 (iOS et iPadOS 27) | validation des shaders | 0/5 | 5/5 | 0/5 |
| les mêmes | sans validation | 5/5 | 5/5 | 0/5 |
| iPad Pro M4 | validation de l'API seule | 5/5 | 5/5 | 0/5 |
| Mac M4 Pro (macOS 27.2) | avec ou sans validation | 5/5 | 5/5 | 0/5 |

- Les variantes de barrière : portée `Buffers`, barrière sur la ressource, `before` réduit au vertex, capture indirecte, capture qui rastérise, enregistrements `Shared`. Toutes se comportent comme le témoin sous la validation des shaders d'iOS.
- La barrière est admise sur ces GPU : les Metal Feature Set Tables n'excluent pour Apple3 à Apple10 que `fragment` ou `tile` dans `after` et la portée `renderTargets`.
- Aucun message de validation ne signale l'échec.

**Coût de la frontière de passe**, sans validation : images de 16 dessins PerVertex sur des attachements RGBA8 et Depth32Float de 2556 × 1179, barrière et frontière alternées, médiane de 100 paires.

| GPU | Barrière | Frontière de passe | Par frontière |
| --- | --- | --- | --- |
| iPhone 15 Pro | 0,515 ms | 1,501 ms | 62 µs |
| iPhone 18 Pro | 0,165 ms | 0,594 ms | 27 µs |
| iPad Pro M4 | 0,305 ms | 0,872 ms | 36 µs |
| Mac M4 Pro | 0,251 ms | 0,642 ms | 24 µs |

Le chemin indexé paie déjà ce coût : sa capture tourne dans un encodeur de calcul.
