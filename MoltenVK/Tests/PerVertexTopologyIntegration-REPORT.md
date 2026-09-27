# Intégration TES topologique + indirect borné — M4, 27 septembre 2026

## État

Fusion locale `ae3db2aa1a20efc42b534d7107e838aab7bc260f` de l'intégration indirect/TES facteur 1 `3d74986d` avec le jalon TES GPU corrigé `790cacf8`. Le harnais indirect est corrigé dans `7fce02edd2bba28f790ade9cecaf7c60454307e8`. Pin SPIRV-Cross **local et non public** `8de8010424a29b577c984437dccaa422b6462e9c`, figé pour ces tests dans `SPIRV-Cross-integrated-topology-pin`. Aucun push ni publication. La garde de l'extension publique reste fermée.

Les deux chemins conservent des réservations distinctes, bien qu'ils utilisent chacun le slot Metal scratch 12 : `planSize` indirect et `tessSizes[5]` TES déterminent sa taille, `indirectCapacity` distingue la lecture du statut indirect de celle du statut TES, et les deux pipelines helpers sont retenus séparément. La fin de soumission examine les deux types d'échec avant la fence. L'ancien encodeur TES limité au facteur 1 est remplacé par le générateur GPU ; le noyau indirect reste présent dans la même source Metal. Le harnais GPU appelle l'adaptateur de périphérique **uniquement quand son symbole existe** dans la bibliothèque de test.

## Validation sur Apple M4 Pro

macOS 27.2 (26B5091g), Xcode 27.1. Bibliothèque Debug arm64 construite depuis l'archive Git de `ae3db2aa`, avec admission et adaptateur de test ; SHA-256 `a48f0328e68de4366656cff84f30a9a536c944d11db791c51ccea4f0237945b7`. Les exécutions GPU ci-dessous utilisent `MTL_DEBUG_LAYER=1` et `MTL_SHADER_VALIDATION=1`.

| Contrôle | Résultat | Preuve dans `build/integration-topology/` |
| --- | --- | --- |
| Compilation MoltenVK + SPIRV-Cross épinglé | PASS | `tes/dev/PROVENANCE.txt`, bibliothèque dans `tes/dev/build/` |
| Préflight et scratch hôtes | PASS ; deux helpers préparés, onze allocations TES transactionnelles, statuts TES/indirect isolés | `preflight/`, `tes/scratch.log` |
| TES topologique complet | **72/72** ; refus, témoins et mutations attendus | `tes/run.log`, `tes/EVIDENCE.sha256` **487/487** |
| Indirect GPU borné | **121/121** avec témoins avant | `indirect/matrix.log`, `indirect/results.csv`, `indirect/EVIDENCE.sha256` **372/372** |
| Même soumission : indirect Count → TES, puis TES → indexed indirect Count | Deux PASS ; 24/24 invocations, pixels indirects identiques, oracle TES vert, aucun rouge | `mixed/indirect-then-tes.log`, `mixed/tes-then-indirect.log` |
| Même soumission : indirect Count → TES facteur 3 | PASS ; 24/24 invocations et oracle TES échantillonné vert | `mixed/factor3-after.log` |
| Contrôle négatif TES volontairement faux | Échec attendu, exit 2 et **336 pixels rouges** | `mixed/wrong-patch.log` |
| Huit contrôles ordinaires/directs r12 | **8/8** images identiques octet par octet aux références, validation Metal activée | `r12-adapted/CONTROLS.txt`, sources et sorties adaptées |

Les manifestes TES et indirect ont été revérifiés après archivage (`VERIFY.log` dans chaque dossier). Les trois autres dossiers ont aussi des manifestes vérifiés : `mixed` 33/33, `r12-adapted` 25/25 et `preflight` 4/4. Le manifeste indirect original comportait des chemins absolus temporaires : `indirect/EVIDENCE.sha256` reprend les mêmes SHA-256 avec des chemins relatifs ; `indirect/ORIGINAL-EVIDENCE.sha256` conserve l'original. Le runner TES a archivé `git archive HEAD` ; son `dev/PROVENANCE.txt` ne peut donc pas lire le SHA du dépôt et laisse `moltenvk_head` vide. `tes/run.log` enregistre `ae3db2aa`, et `tes/SOURCE-INDEX.txt` indexe les sources. Le harnais r12 historique cherchait l'extension avant d'appeler l'adaptateur de test ; seules ses **copies temporaires** dans `r12-adapted/` ajoutent cet appel. Les sources r12 originales restent intactes.

Une revue Astra indépendante et en lecture seule du merge `ae3db2aa` et du harnais `7fce02ed` n'a relevé aucun défaut fonctionnel P0–P2 dans les conflits examinés : slot 12, statuts, fin de soumission, admission, bindings, génération Metal, cache et adaptateur de test. Elle a vérifié les manifestes TES 487/487, indirect 372/372, préflight 4/4, l'index des 251 sources et l'empreinte de la bibliothèque. Cette revue était **statique** : elle n'a ni compilé ni exécuté le GPU, et ne remplace pas la revue finale upstream.

## Reproduction

Depuis `MoltenVK-integrated-topology/`, avec `External/SPIRV-Cross` pointant vers le worktree figé au pin :

```sh
bash MoltenVK/Tests/run-pervertex-helper-preflight-tests.sh build/integration-topology-recheck/preflight
bash MoltenVK/Tests/run-pervertex-tes-tests.sh build/integration-topology-recheck/tes
bash MoltenVK/Tests/run-pervertex-indirect-gpu-tests.sh build/integration-topology-recheck/tes/dev/build/moltenvk/MoltenVK/libMoltenVK.1.4.3.dylib ../MoltenVK-indirect-gpu/build/indirect-gpu/lib-before/arm64/MoltenVK/libMoltenVK.1.4.3.dylib build/integration-topology-recheck/indirect
```

Pour les essais mixtes, recompiler `MoltenVK/Tests/PerVertexIndirectGPUTests.cpp` contre la bibliothèque `tes/dev/build/moltenvk/MoltenVK/libMoltenVK.1.4.3.dylib` archivée, avec `-Wl,-rpath,<dossier de cette bibliothèque>`, puis utiliser les SPIR-V de `mixed/shaders/` :

```sh
PERVERTEX_TEST_INCLUDE_TES=1 <exécutable> build/integration-topology/mixed/shaders draw-count u32 two compute <préfixe-sortie>
PERVERTEX_TEST_INCLUDE_TES=1 PERVERTEX_TEST_TES_FIRST=1 <exécutable> build/integration-topology/mixed/shaders indexed-count u16 two copy <préfixe-sortie>
PERVERTEX_TEST_INCLUDE_TES=1 <exécutable> build/integration-topology/mixed/factor3 draw-count u32 two compute <préfixe-sortie>
PERVERTEX_TEST_INCLUDE_TES=1 PERVERTEX_TEST_TES_WRONG_PATCH=1 <exécutable> build/integration-topology/mixed/shaders draw-count u32 two compute <préfixe-sortie>
```

Activer `MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1` et un timeout de 30 secondes pour chaque commande. Le dernier cas doit sortir avec le code 2. Les contrôles r12 utilisent les deux sources C++ archivées dans `r12-adapted/`, avec `dlsym(RTLD_DEFAULT, "mvkEnableTESFixtureDevice")` avant l'énumération des extensions ; `CONTROLS.txt` compare les images aux références de `expanded-reproducer/indexed-integration`.

## Limites ouvertes

L'indirect reste borné par une capacité R réservée avant soumission ; ce jalon ne valide ni une continuation Vulkan, ni tous les comptes indirects légaux. Le test mixte facteur 3 vérifie quelques pixels TES et la cohabitation des deux chemins ; la matrice TES 72/72 fournit séparément l'oracle topologique complet. Aucun essai M1/M3, mesh, mesure de performance soutenue ou pin SPIRV-Cross public ici. Les modes TES hors triangles `equal_spacing` et niveaux uniformes 1 à 3 restent refusés. Une revue Astra indépendante des **SHA finaux** et des preuves intégrées reste nécessaire avant toute proposition upstream.
