# Bornes de `DrawIndirectCount` pour PerVertexKHR indirect : analyse CPU

Point 2 de la clôture de PerVertexKHR, option (a) : contrat restreint, extension fermée par défaut. La demande d'Astra est de partir du code actuel, d'établir les bornes pour tout `DrawIndirectCount` légal et de proposer un traitement cohérent. Deux choses sont exclues : un plafond privé, et une réduction silencieuse de `maxDrawIndirectCount` pour tous les dessins de MoltenVK.

Analyse sur `MoltenVK-pervertex-generic`, runtime `a3f02d1c`. Aucun code n'est modifié.

## 1. Ce que fait le code actuel

La formule notée dans le plan et dans `MoltenVK-indirect-continuation-r2/WORKLOG.md` (« `1024 + 20 × maxDrawCount` octets dans un seul buffer de plan ») est **périmée**. Aujourd'hui, `recordPerVertexIndirectDraw()` (`MVKCommandBuffer.mm:523-560`) réserve séparément deux choses :
- **Un plan de taille fixe** : `1024` octets, plus `(pas de balayage + 3) × 256` octets avec le redémarrage de primitives. Cette taille est calculée pour le plafond d'identifiants `UINT32_MAX` et ne dépend pas du nombre de dessins.
- **Un instantané par commande**, quand `drawCount > 1` : `drawCount × 16` octets, ou `× 20` pour les dessins indexés, c'est-à-dire la commande Vulkan de chaque dessin, figée en phase 0. Un dessin unique fige sa commande dans le plan (mots 48 à 52).

Pour `vkCmdDrawIndirectCount`, `drawCount` est `maxDrawCount`, car le compte réel n'est connu que du GPU.

## 2. Les bornes, pour tout dessin légal

**B1 : l'instantané tient toujours dans un MTLBuffer.**
- Vulkan impose, pour `vkCmdDrawIndirect` et `vkCmdDrawIndexedIndirect` si `drawCount > 1`, et pour les variantes `…Count` si `maxDrawCount ≥ 1` : `stride × (n − 1) + offset + sizeof(commande) ≤ taille du buffer`, avec `stride ≥ sizeof(commande)` (16 ou 20).
- Donc `n × sizeof(commande) ≤ stride × (n − 1) + sizeof(commande) ≤ taille − offset`.
- Dans MoltenVK, un `VkBuffer` ne dépasse pas `maxMTLBufferSize` : `maxBufferSize` et `maxMemoryAllocationSize` valent cette limite (`MVKDevice.mm:859`, `970`, `1079`), et la liaison d'un buffer à une mémoire plus grande est refusée (`MVKDeviceMemory.mm:140`).
- L'instantané fait donc au plus l'étendue lue dans le buffer d'arguments, et le refus à l'enregistrement (`MVKCommandBuffer.mm:547`) **n'est jamais atteint en usage valide**.
- Pire cas M4 Pro (`maxMTLBufferSize = 41 747 087 360`) : 2 609 192 960 dessins non indexés, ou 2 087 354 368 indexés. L'instantané fait alors 41,7 Go.

**B2 : la grille de la phase 0 tient.** La phase 0 envoie `⌈n / largeur⌉` groupes (`MVKCmdDraw.mm:1159`). Au pire légal, avec une largeur de 32, cela fait 81,5 millions de groupes, sous la limite que MoltenVK annonce (`maxComputeWorkGroupCount` = 2³⁰, soit 1 073 741 824, `MVKDevice.mm:3167`). La limite propre de Metal n'est pas vérifiée ici.

**B3 : le plan ne dépend pas de `n`.** Voir le § 1.

**B4 : l'arithmétique ne déborde pas.** Le noyau adresse arguments et instantané en `ulong` (`MVKCommandPipelineStateFactoryShaderSource.h`, phase 0). Côté CPU, tout est en `uint64` (`MVKCommandBuffer.mm:546`), et `mvkSizePerVertexIndirectReplay()` refuse un compte figé qui dépasserait l'instantané (`MVKPerVertexScratch.h:43`).

**B5 : la mémoire est proportionnelle à `maxDrawCount`, pas au compte réel.**
- L'instantané double au plus l'étendue du buffer d'arguments, une fois par passe multiview.
- Si l'allocation échoue, `vkQueueSubmit` rend `VK_ERROR_OUT_OF_DEVICE_MEMORY` avant toute exécution (`MVKCommandBuffer.mm:620`). C'est un résultat permis par Vulkan, pas un refus d'un dessin légal.
- Le réduire au compte réel demande de connaître ce compte avant la soumission. C'est la continuation, exclue par l'option (a).

**B6 : l'encodage du rejeu est proportionnel au compte réel. C'est la seule vraie limite d'échelle.**
- Après la phase 0, le CPU encode, pour chaque dessin figé, une planification, des tables, une capture et un dessin de rejeu (`MVKCmdDraw.mm:1191`, boucle sur `frozenDraws`). Cela fait au moins un encodeur de calcul et un encodeur de rendu par dessin, dessins vides compris.
- Aucune borne de buffer ne s'applique, mais le temps et la mémoire d'encodage croissent avec le compte. Pour un compte de plusieurs millions, l'encodage deviendrait impraticable. **Ce n'est pas mesuré.**

**B7, hors du sujet de `DrawIndirectCount`.** Chaque dessin reste limité à `UINT32_MAX` enregistrements (sommets × instances × vues). Au-delà, le GPU le refuse et le device est perdu à la fin de la soumission. C'est le plafond d'identifiants, qui relève de la continuation, pas de ce point.

## 3. Conclusion

- **Aucun plafond privé n'est nécessaire sur l'instantané**, et `maxDrawIndirectCount` peut rester à `UINT32_MAX` : tout compte légal tient dans les buffers Metal (B1 à B4).
- Le coût mémoire (B5) est borné par l'étendue du buffer d'arguments, et son échec est un code d'erreur légal.
- **Le point ouvert réel est B6**, l'encodage du rejeu proportionnel au compte réel.

## 4. Traitement proposé et oracles, avant tout code

1. **Verrouiller B1, B3 et B4 par une vérification CPU.**
   - Les tailles du plan et de l'instantané passent dans deux fonctions sans état de `MVKPerVertexScratch.h`, sans changement de comportement.
   - Un test hôte vérifie, pour les deux tailles de commande, des strides de `sizeof(commande)` à 4 × `sizeof`, des offsets alignés et 1 à 32 passes multiview, que l'instantané ne dépasse jamais l'étendue légale du buffer d'arguments, jusqu'au pire cas M4 et au-delà.
   - Il vérifie aussi que `mvkSizePerVertexIndirectReplay()` refuse un compte figé plus grand que l'instantané.
   - Oracle : rouge si l'une des fonctions calcule une taille qui dépasse l'étendue légale ; vert sinon.
2. **Écrire la limite de B6 et la mesurer.**
   - Un essai GPU court sur M4, sous validation Metal : `vkCmdDrawIndirectCount` avec un `maxDrawCount` grand (1 million, buffer de 16 Mo) et un compte réel petit. Oracle : pixels corrects, instantané de 16 Mo alloué, rendu inchangé.
   - Puis un compte réel croissant (1, 100, 10 000), en mesurant le temps d'encodage du rejeu et le nombre d'encodeurs.
   - Oracle : rendu correct à chaque taille ; courbe mesurée et publiée, sans seuil caché.
3. **Proposer ensuite, séparément, un rejeu groupé.** Tables et préfixes par dessin seraient alloués après le plan, à partir du compte figé, et une seule capture et un seul rejeu serviraient à tous les dessins. L'encodage ne dépendrait plus du compte. C'est une conception à part, avec son propre oracle (nombre d'encodeurs indépendant du compte), à soumettre avant tout code.

Le plan partagé (`PLAN-PERVERTEX-UPSTREAM.md`, ligne 145) décrit encore l'ancienne formule. Je ne le modifie pas ; ce document en donne l'état actuel.
