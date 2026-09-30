# PerVertexKHR hors TES : état au 30 septembre 2026 (HEAD `7ce08935`)

Le jalon TES restreint est clos (`PerVertexTES/README.md`, figé à `66f9fd97`). Cet état couvre les pipelines PerVertexKHR sans tessellation : vertex et fragment, et le mesh ouvert par l'adaptateur de test. Aucun nouveau refus n'est ouvert ici.

## 1. Ce qui est admis

**Chemin natif.** Sur un GPU Apple10, avec MSL 4.0, une topologie triangulaire et sans `BaryCoordKHR`, le fragment lit directement les valeurs des sommets (`MVKPipeline.mm:1391`). Aucun GPU Apple10 n'est disponible : ce chemin n'a jamais rendu à travers Vulkan.

**Chemin portable (capture puis rejeu), sur tout GPU avec MSL 2.4.**
- **Pipelines.**
  - Étages vertex et fragment en SPIR-V.
  - Topologies statiques : points, lignes (listes, bandes), triangles (listes, bandes, éventails).
  - Rastérisation remplie ; au plus une vue multiview.
  - `BaryCoordKHR` et `BaryCoordNoPerspKHR` portables.
- **Dessins.**
  - Directs et indexés, avec des indices uint8, uint16 ou uint32.
  - Redémarrage de primitive, statique ou dynamique ; instances ; `firstVertex`, `firstInstance`, `vertexOffset`.
  - Dessins indirects et indirects Count, sous le contrat restreint : le plan GPU fige les arguments, et le rejeu est dimensionné sur le plan.
- **Command buffers.** Secondaires ; préremplissage Metal différé et immédiat pour les dessins directs.
- **Mesh.** Un mesh et un fragment, sans ressources dans l'étage mesh, en dessins directs. Il n'est ouvert que par l'adaptateur de test.

**Garde publique.** Elle est fermée sur toutes les plateformes (`MVKDevice.mm:3632-3636`) ; seul l'adaptateur de test ouvre l'extension.

## 2. Ce qui est prouvé au HEAD

La passe complète `build/astra/final-r5-7ce08935/` rejoue les mêmes étapes que `final-r4`, qui datait du runtime `7758838b`. Tout tourne sous validation Metal, sur la bibliothèque de test de `d3b4457d`.

| Étape | Résultat |
| --- | --- |
| Matrice indirecte | 127/127, résultats identiques à `final-r4` cas par cas |
| Continuation | 40/40 ; binaire 21/21 ; suite de perte 12/12 ; oracles TES de la continuation 14/14 |
| Attachements séparés | 0 écart inattendu |
| Mesh | 41/41 |
| TES restreint | 142/142 |
| Contrôles hôte | 10 suites, dont 90 088 contrôles des tables indirectes et 74 136 motifs de redémarrage |
| CTS `fragment_shading_barycentric` | 1 213 réussites, 1 638 refus, **aucun résultat faux** ; ensembles identiques à `final-r4`, avec et sans validation |
| CTS mesh | 9 réussites, 478 refus ; ensembles identiques à `final-r4` |
| Oracles de perte | 0 écart inattendu, 24 exécutions « blocker » attendues (6 dans `final-r4`, avant l'ajout d'oracles) |

`EVIDENCE.sha256` compte 1 236 entrées (sha256 du manifeste `f89d7f49…`). Les arbres de sources archivés par les sous-runners en sont exclus ; chacun a son propre manifeste.

Seul un Apple M4 Pro sous macOS 27.2 est prouvé.

## 3. Ce qui empêche encore l'ouverture publique

**Les 1 638 refus CTS, par cause.**

| Cause | Cas | Remarque |
| --- | --- | --- |
| Topologies à adjacence | 792 | Refusées par le rejeu. Le chemin ordinaire les dessine comme des primitives simples, sans retirer les sommets d'adjacence (`mvk_datatypes.mm:497`). |
| Étage mesh | 690 | Adaptateur de test seulement. |
| Topologie dynamique (`VK_DYNAMIC_STATE_PRIMITIVE_TOPOLOGY`) | 120 | Refusée par la porte PerVertex (`MVKPipeline.mm:1449`) à `7ce08935`. Tous les cas `provoking_last` de la CTS sont dans cette famille ou celle de l'adjacence. **Depuis `162a23a4`**, l'admission expérimentale l'accepte ; à `fb3970cc`, il reste 8 résultats faux en validé, tous MSAA (`PerVertexDynamicTopology-REPORT.md`, sections 11 et 12). |
| Tessellation | 36 | Hors du contrat TES restreint. |

**Les autres usages Vulkan valides encore refusés hors TES.**
- **Pipeline.**
  - Plus d'une vue multiview, ou les vues par index de device.
  - Les modes de polygone ligne et point.
  - Le mode de polygone, l'abandon de rastérisation ou le sommet provoquant rendus dynamiques.
- **Dessins indirects.** Avec des liaisons de sommets à diviseur nul, ou sous préremplissage Metal immédiat.
- **Attachements.** La capture indexée refuse les attachements memoryless et certains modes de résolution.
- **Limites de mise en œuvre.** Les emplacements de buffer libres, le budget de varyings du rejeu, et les formes de sortie que le rejeu ne sait pas représenter.

**Les preuves manquantes.**
- **Chemin natif Apple10.** Jamais rendu à travers Vulkan, faute de matériel.
- **Sommet provoquant « dernier ».** Il n'est exposé qu'avec l'API privée Metal (`MVKDevice.mm:791`), et seuls les contrôles hôte en vérifient l'ordre. Aucun essai GPU ne l'utilise : les cas CTS `weights.provoking_last` sont construits avec `provokingVertexLast = false`, et les bibliothèques de test sont compilées sans API privée (correction du 30 septembre 2026 ; une version antérieure de cette ligne affirmait le contraire). Il reste **explicitement non qualifié** (avis d'Astra du 30 septembre 2026).
- **Autres GPU.** M1, M3, Intel et iOS ne sont pas testés ; ils restent pour la fin.

**Les points gelés ou bornés.**
- **Plafond d'enregistrements.** Un dessin au-delà de `UINT32_MAX` enregistrements perd le device (B7 de `PerVertexIndirectCount-ANALYSIS.md`).
- **Volet perte de device.** Il est gelé : R1, R5, R6 et le reste de R3 attendent, et les oracles de perte gardent 24 exécutions « blocker » connues.

## 4. Premier écart traité : les preuves hors TES ne couvraient pas le runtime courant

`final-r4` avait tourné sur `7758838b`. Depuis, 15 commits de runtime sont arrivés : six du volet perte (`d24159ce` à `a3f02d1c`) et les jalons TES et mesh. La passe `final-r5-7ce08935` les couvre maintenant. Elle donne les mêmes résultats, cas par cas pour la CTS et la matrice indirecte.

## 5. Une ligne périmée du plan

La ligne 144 de `PLAN-PERVERTEX-UPSTREAM.md` (« Preuves de reprise indirecte à ajouter ») dit qu'aucun scénario ne couvre les secondaires, le préremplissage Metal ou `synchronousQueueSubmits`. Ils sont couverts :
- `run-pervertex-continuation-tests.sh` couvre `PERVERTEX_TEST_SECONDARY=1` et les modes synchrone et asynchrone ;
- `run-pervertex-indirect-gpu-tests.sh` couvre les cas `prefill1-*` et `prefill2-*`.

Je ne modifie pas le plan.
