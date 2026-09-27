# Intégration TES float32 + indirect borné — matrices M4

## État au 27 septembre 2026

Fusion locale `713e6899` du correctif TES ordinaire de Claude `d3732680` dans le jalon TES/indirect `59deb4ab`, puis garde de capacité du scratch float32 `cb3d8a43` après un constat P2 de la revue Astra. Pin SPIRV-Cross local `68720b61`. Aucun push ni publication ; garde publique fermée. Les matrices TES et indirecte ont été rejouées sur une même bibliothèque issue du commit `a46a90e6496794e95ea32e6b143263c1c7062916` (ce commit n'ajoute qu'une première version de ce rapport après `cb3d8a43`).

## Contrôles ciblés préalables

Apple M4 Pro, macOS 27.2 (26B5091g), Xcode 27.1. Les bibliothèques arm64 Debug ont été construites depuis `cb3d8a43` propre, avec `MoltenVK/Tests/PerVertexTES/build-library.sh` : développement avec admission et adaptateur de test, shipping sans eux. Leurs SHA-256 sont `b9d3f3df40fe207bfb8ca75cd33b17e69b1d132be51afbc095b7589212abb964` et `fdceaae574de3a5e0d229cd0c44f140b1d49e535ed2b5ae4163ac42aabda8827`. Le préflight hôte des deux helpers passe. Les shaders ont été repris des fixtures TES `final-e/shaders` de Claude et mixtes `integration-topology/mixed/shaders` du jalon précédent ; leurs binaires exacts sont archivés.

| Exécution sur le binaire fusionné | Résultat | Validation Metal |
| --- | --- | --- |
| Ordinaire float32 direct, développement | PASS `ordinary-levels-direct ccw` | API + GPU |
| TES PerVertex `nextafter(1,+∞)` | PASS ; 3 136 pixels couverts, 0 écart de couverture ou de valeur avec le TES ordinaire | API + GPU |
| Indirect Count GPU `draw-count u32 two compute` | PASS ; 24/24 invocations VS, 0 pixel divergent | API + GPU |
| Même soumission, indirect puis TES | PASS ; 24/24 invocations, oracle TES vert | API + GPU |
| Même soumission, TES puis indexed indirect Count | PASS ; 24/24 invocations, oracle TES vert | API + GPU |
| Contrôle TES au mauvais patch | Échec attendu, exit 2, 336 pixels rouges | API + GPU |
| Ordinaire float32 direct, shipping | PASS | API + GPU |
| Ordinaire float32 indirect, shipping | PASS | API seule |

Les journaux, les deux bibliothèques, leur provenance et les SPIR-V sont conservés dans `build/integration-float32/targeted/` (ignoré par Git). `EVIDENCE.sha256` vérifié : 53/53 fichiers. Les scénarios utilisent le programme `topology.cpp` ou `PerVertexIndirectGPUTests.cpp` du commit `cb3d8a43`, recompilés et liés à la bibliothèque correspondante. Les essais GPU ont utilisé `gtimeout -k 2` avec 30 ou 60 secondes. Ce premier lot est distinct des matrices complètes reconstruites ensuite depuis `a46a90e6`.

## Matrices complètes sur une même bibliothèque

La bibliothèque développement arm64 Debug de `build/integration-float32/tes/dev/` a le SHA-256 `3f1073d17487dad611184cd91dc06394dd7023769daa7084567f3685b2ad54dd`. `tes/run.log` enregistre le HEAD `a46a90e6` et le pin `68720b61` ; les `PROVENANCE.txt` des six bibliothèques issues de `git archive HEAD` ne peuvent pas relire le SHA Git dans leur archive sans `.git`, mais enregistrent le pin et chaque SHA de bibliothèque. La bibliothèque shipping de cette matrice a le SHA-256 `fe971b86b6ff64e006469f265148968c6520cfdefc1af45d59b19cd392a068e4`.

| Suite | Résultat M4 | Archive vérifiée |
| --- | --- | --- |
| TES topologique, ordinaires float32, shipping, refus et mutations | **82/82 PASS** ; Metal API/GPU Validation, sauf TES ordinaire indirect sous validation API seule | `build/integration-float32/tes/`, manifeste relatif **779/779** |
| Quatre formes indirectes bornées, producteurs GPU, frontières et témoins | **121/121 PASS** sur la bibliothèque TES ci-dessus ; Metal API/GPU Validation | `build/integration-float32/indirect/`, manifeste relatif **372/372** ; original absolu conservé |
| Même soumission : indirect Count → TES, puis TES → indexed indirect Count | Deux PASS ; 24/24 invocations VS, zéro pixel indirect divergent, oracle TES vert | `build/integration-float32/mixed/`, manifeste **34/34** |
| Mixte TES facteur 3 ; témoin TES au mauvais patch | PASS facteur 3 ; témoin exit 2 et 336 pixels rouges | Même manifeste **34/34** |

Les cinq shaders mixtes TES proviennent de la matrice TES du même HEAD et les cinq shaders indirects de la matrice indirecte du même HEAD ; le cas facteur 3 conserve la fixture spécialisée du jalon précédent. Le programme mixte a été recompilé depuis `PerVertexIndirectGPUTests.cpp` de ce checkout contre la bibliothèque ci-dessus. Les trois manifestes ont été revérifiés après archivage. Cela prouve la cohabitation des deux chemins sur cette bibliothèque et cette pile M4, dans les capacités admises par leurs harnais.

Reproduction des matrices depuis ce worktree, avec le pin local et la bibliothèque de référence avant correction indirecte indiquée ci-dessous :

```sh
bash MoltenVK/Tests/run-pervertex-tes-tests.sh build/integration-float32-recheck/tes
bash MoltenVK/Tests/run-pervertex-indirect-gpu-tests.sh build/integration-float32-recheck/tes/dev/build/moltenvk/MoltenVK/libMoltenVK.1.4.3.dylib ../MoltenVK-indirect-gpu/build/indirect-gpu/lib-before/arm64/MoltenVK/libMoltenVK.1.4.3.dylib build/integration-float32-recheck/indirect
```

Pour vérifier les archives existantes, lancer `shasum -a 256 -c EVIDENCE.sha256` **depuis chacun** des dossiers `tes/`, `indirect/` et `mixed/`. Les commandes des deux ordres mixtes et du facteur 3 suivent celles du rapport `PerVertexTopologyIntegration-REPORT.md`, avec `build/integration-float32/tes/dev/build/moltenvk/MoltenVK/libMoltenVK.1.4.3.dylib` et les shaders conservés dans `build/integration-float32/mixed/`. Le témoin au mauvais patch doit retourner 2.

## Reproduction ciblée

Depuis ce worktree, avec `External/SPIRV-Cross` au pin indiqué, construire les bibliothèques :

```sh
bash MoltenVK/Tests/PerVertexTES/build-library.sh /private/tmp/pervertex-integrated-float32-20260927/dev ON ON
bash MoltenVK/Tests/PerVertexTES/build-library.sh /private/tmp/pervertex-integrated-float32-20260927/shipping OFF OFF
bash MoltenVK/Tests/run-pervertex-helper-preflight-tests.sh /private/tmp/pervertex-integrated-float32-20260927/preflight
```

Avec les SPIR-V archivés dans `build/integration-float32/targeted/shaders/`, les mêmes exécutions sont reproductibles ainsi (depuis ce worktree) :

```sh
e="$(pwd)/build/integration-float32/targeted"
dev="$e/libs/dev/libMoltenVK.1.4.3.dylib"
shipping="$e/libs/shipping/libMoltenVK.1.4.3.dylib"
shaders="$e/shaders"
mkdir -p /private/tmp/pervertex-float32-replay
xcrun clang++ -std=c++17 -arch arm64 -O1 -Wall -Wextra -Werror -Wno-missing-field-initializers -DVK_ENABLE_BETA_EXTENSIONS -IExternal/Vulkan-Headers/include MoltenVK/Tests/PerVertexTES/topology.cpp "$dev" -Wl,-rpath,"$e/libs/dev" -Wl,-U,_mvkEnableTESFixtureDevice -o /private/tmp/pervertex-float32-replay/topology
xcrun clang++ -std=c++17 -arch arm64 -O1 -Wall -Wextra -Werror -Wno-missing-field-initializers -DVK_ENABLE_BETA_EXTENSIONS -IExternal/Vulkan-Headers/include MoltenVK/Tests/PerVertexTES/topology.cpp "$shipping" -Wl,-rpath,"$e/libs/shipping" -Wl,-U,_mvkEnableTESFixtureDevice -o /private/tmp/pervertex-float32-replay/topology-shipping
xcrun clang++ -arch arm64 -std=c++17 -O2 -Wall -Wextra -Werror -Wno-missing-field-initializers -IExternal/Vulkan-Headers/include MoltenVK/Tests/PerVertexIndirectGPUTests.cpp "$dev" -Wl,-rpath,"$e/libs/dev" -o /private/tmp/pervertex-float32-replay/indirect
unset DYLD_LIBRARY_PATH DYLD_INSERT_LIBRARIES
export MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 MVK_CONFIG_LOG_LEVEL=2 MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS=0 MVK_PERVERTEX_INDIRECT_RECORD_CAPACITY=128
gtimeout -k 2 60 /private/tmp/pervertex-float32-replay/topology "$shaders" ordinary-levels-direct ccw /private/tmp/pervertex-float32-replay/dev-direct
gtimeout -k 2 60 /private/tmp/pervertex-float32-replay/topology "$shaders" next ccw /private/tmp/pervertex-float32-replay/next
gtimeout -k 2 30 /private/tmp/pervertex-float32-replay/indirect "$shaders" draw-count u32 two compute /private/tmp/pervertex-float32-replay/indirect-only
PERVERTEX_TEST_INCLUDE_TES=1 gtimeout -k 2 30 /private/tmp/pervertex-float32-replay/indirect "$shaders" draw-count u32 two compute /private/tmp/pervertex-float32-replay/indirect-then-tes
PERVERTEX_TEST_INCLUDE_TES=1 PERVERTEX_TEST_TES_FIRST=1 gtimeout -k 2 30 /private/tmp/pervertex-float32-replay/indirect "$shaders" indexed-count u16 two copy /private/tmp/pervertex-float32-replay/tes-then-indirect
PERVERTEX_TEST_INCLUDE_TES=1 PERVERTEX_TEST_TES_WRONG_PATCH=1 gtimeout -k 2 30 /private/tmp/pervertex-float32-replay/indirect "$shaders" draw-count u32 two compute /private/tmp/pervertex-float32-replay/wrong-patch
gtimeout -k 2 60 /private/tmp/pervertex-float32-replay/topology-shipping "$shaders" ordinary-levels-direct ccw /private/tmp/pervertex-float32-replay/shipping-direct
MTL_SHADER_VALIDATION=0 gtimeout -k 2 60 /private/tmp/pervertex-float32-replay/topology-shipping "$shaders" ordinary-levels-indirect ccw /private/tmp/pervertex-float32-replay/shipping-indirect
```

Le contrôle `wrong-patch` doit sortir avec le code 2 et 336 pixels rouges ; les sept autres avec 0. Claude a reproduit l'absence de sortie du dessin TES ordinaire indirect sous GPU Validation avant et après son correctif : le dernier PASS ne prouve donc que l'API Validation pour ce cas.

## Travail restant

Tester au niveau Vulkan le refus du nouveau scratch float32 hors capacité, puis mesurer le coût du dispatch supplémentaire. La preuve est M4 seulement ; M1/M3 et le mesh restent ouverts. L'indirect conserve sa borne R et aucune continuation Vulkan générale n'est implémentée. Une revue Astra indépendante des SHA finaux reste requise avant toute proposition upstream.
