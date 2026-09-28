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

**Lecture du rapport.** Chaque cas finit en `PASS`, `FAIL` ou `SKIPPED` (capacité absente, avec sa raison). Le rapport global vaut `PASS`, `FAIL` ou `INCOMPLETE`.

**Arrêt en cours de cas.** Si un cas arrête l'app, le `journal.txt` du run garde un `START` sans `END`. Le rapport du lancement suivant le liste sous `interrupted_previous_runs`.

## Ce qui a été vérifié

- Construction non signée, pour l'appareil et pour le simulateur.
- Construction signée pour l'équipe personnelle : le profil couvre l'iPhone 18 Pro, l'iPhone 15 Pro, l'iPad Pro M4 et l'iPad Pro 9,7″.
- Sur le simulateur iOS 27.0 : l'app exécute les 16 cas et écrit son rapport. La garde publique passe, et les 15 autres cas sont ignorés faute de capacités.
- **Aucun essai sur appareil à ce stade.**
