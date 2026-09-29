# Attente Metal externe : conception révisée du retrait différé

Ce document est soumis à la revue Astra **avant toute implémentation**. Il révise la proposition de la troisième revue (rapport `PerVertexContinuation-REPORT.md`, section « Point 3 : attente Metal externe — blocage maintenu, refonte proposée »).

Seuls R9 (`d24159ce`) et R8 (`67dd59d4`, complété en `1deebd18` et `d4110762`) sont codés. Sauf mention contraire, les références de lignes portent sur le runtime de `7758838b`, identique à celui de `c78c0289`.

**Révision 3.** La revue Astra indépendante de la révision 2 (`6dee5d90`) a conclu NO-GO pour l'implémenter telle qu'écrite. Cette révision répond à chacun de ses constats (§0). La publication anticipée de la perte (R6) n'est pas codée et ne le sera pas avant une nouvelle revue. Les reproducteurs des constats vérifiables aujourd'hui sont écrits (§5.1).

**Révision 4.** La revue de la révision 3 (`7838e797`) conclut encore NO-GO pour coder R6, avec quatre P1 ; elle reconnaît les corrections de `destroyNow()` et le principe du jeton de R9. Cette révision répond aux quatre P1 et aux demandes sur les oracles (§0 bis). **R9 est implémenté seul** (`d24159ce`), comme la revue l'autorise. R6 reste non codé.

**Révision 5.** La revue de la révision 4 (`a253c42c`) conclut encore NO-GO pour R6. Elle relève un fil commun à deux attentes qui peut créer un cycle, des handlers Metal protégés ensemble alors qu'ils s'exécutent séparément, une présentation sans callback qui pourrait bloquer la file de retrait, une R8 incohérente avec R6, R7 et O11, et des oracles de présentation qui pouvaient rester non couverts. Une sonde de présentation (`7e7d53e8`) a d'abord été mesurée (§3.13) : elle **invalide** la phase 2 du retrait de la révision 4. Cette révision répond à chaque point (§0 ter). R6 reste non codé.

**Révision 6.** La revue de la révision 5 (`0ac8e6f5`) conclut encore NO-GO pour R6. Son blocage principal : en R8, un encodage commencé avant `markLost()` peut commiter après l'inventaire du travail protégé, et `vkFreeMemory` rendrait alors des pages que le GPU utilisera encore. Elle demande aussi de placer R4 avant la porte de R6 et de renforcer les oracles de progression et d'ordre des handlers. Elle autorisait le **jeton de présentation comme correctif isolé** ; une mesure préalable a montré qu'il ne corrige aucun défaut en usage valide aujourd'hui (§5.2), il reste donc une pièce de R5. Cette révision répond à chaque point (§0 quater). R6 reste non codé.

**Révision 7.** La revue de la révision 6 (`91bcd0d4`) conclut encore NO-GO pour R6. Elle reconnaît que fermer l'inventaire de R8 après les encodages corrige la course des soumissions, et accepte que le jeton de présentation reste dans R5. Deux points restent (§0 quinquies). R6 et R5 restent non codés.

**Révision 8.** La revue de la révision 7 (`f97faeb7`) donne un **GO limité pour implémenter R5 et R8 sous leurs oracles**, et maintient le **NO-GO pour activer R6** : O17 n'est pas reproduit. Avant de tenir R8 pour vérifié, elle demande de renforcer O20, de prouver que `vkFreeMemory` attend la fin du handler de fin, et de noter que le chemin sans mémoire unifiée n'a pas d'essai matériel sur M4. **R8 est implémenté** (`67dd59d4`) ; cette révision rend compte de ses oracles (§0 sexies). **R5 n'est pas commencé.** R6 reste fermé.

**Révision 9.** La revue de la révision 8 juge que R8 démontre le mécanisme visé, mais n'est pas clos ; R6 reste fermé, le GO limité pour R5 demeure. Elle relève trois cas que les oracles M4 ne couvrent pas. `1deebd18` les corrige (§0 septies). R5 n'est toujours pas commencé.

**Révision 10.** La revue de R8 bis (`975961a2`) confirme ses trois corrections dans le code ; R8 reste à qualifier sans mémoire unifiée (le kit de §0 septies attend un Mac Intel à Radeon, en fin de parcours avec M1 et M3). Avant de coder R5, sous le GO limité, trois questions sont soumises à la revue, avec les faits mesurés qui les fondent (§0 octies). R5 n'est pas commencé.

**Révision 11.** La revue des questions R5 retient l'**option C** : R1 et R5 restent gelés jusqu'à leur intégration avec R6 ; leurs témoins de mécanisme en usage aujourd'hui invalide seront à rejouer sur la bibliothèque qui intègre R1, R5 et R6, où la séquence devient valide. Elle accepte O17 au niveau Metal (fait, §3.13), puis la reproduction du constat 3 et la correction de ce seul chemin de R3 : **reproduit et corrigé** (`275b5226`, `630b183e`, §0 octies). L'activation du reste de R3 reste soumise à ses propres oracles. La question 4 (critère d'O17) attend sa réponse. R6 reste fermé.

**Révision 12.** La revue tranche la question 4 : **option b**, avec un oracle d'**ordre des événements** au niveau Vulkan, ni a ni c. `nextDrawable` doit être entré avant la perte et ne pas avoir rendu la main. Avant R10, un fil d'encodage y attend. Après R10, aucun fil d'encodage n'y attend, la perte est publiée avant le retour de `nextDrawable`, et le drawable tardif est rendu. R6 reste fermé jusqu'à ce rouge/vert. **Sur ce fondement, R10 est codé** (`a3f02d1c`) sous l'oracle `drawable-wait-loss` (`3319cdd6`, `815b2cbe`) : 6/6 rouges avant, 6/6 verts après (§0 nonies).

## 0 nonies. O17 au niveau Vulkan et R10 (révision 12)

**L'oracle** `drawable-wait-loss` (`3319cdd6`). Couche détachée de toute fenêtre, macOS 27.2 :
1. un ancien swapchain présente deux images derrière du travail bloqué par l'application, et garde une troisième image acquise ;
2. un swapchain de remplacement, de même taille, est créé pendant que ces présentations attendent ;
3. le travail est libéré ;
4. les trois images du remplacement sont effacées, ce qui prend et retient trois drawables ;
5. l'effacement de l'image gardée demande un 4ᵉ drawable, qui attend environ 1 s ;
6. le device est perdu 50 ms après l'entrée dans cet appel.

Un swizzle chronomètre `nextDrawable` et note le fil appelant ; `mvkTestGetLossCounters` donne les encodages en cours. Où cette attente ne se produit pas, le mode sort en SKIP (`815b2cbe`).

**Cause non attribuée.** Les présentations n'avaient pas commencé à la recréation (`mvkTestGetUnpresentedImageCount` à 0) : MoltenVK n'a donc forcé aucune fin, et l'attente n'est pas celle de la recette Metal du §3.13. Elle est reproduite, pas expliquée.

**R10** (`a3f02d1c`). Chaque essai de `getCAMetalDrawable()` demande le drawable sur une file série de la surface : une par couche, partagée par un swapchain et son remplacement. L'encodage attend une notification, et vérifie toutes les millisecondes si la perte a commencé ; si oui, il abandonne la demande et continue sans drawable. Le drawable arrivé plus tard est relâché à la fin de la demande et retourne à la couche. La demande ne touche que la couche et un enregistrement partagé, ni l'image ni le device. Hors perte, le nombre d'essais et le délai de chacun sont ceux d'avant.

**Le chemin sans drawable, vérifié avant R10.** R10 le rend accessible dès chaque perte, alors qu'il ne l'était qu'après `imageCount` délais d'expiration. Avec `PERVERTEX_DRAWABLE_NIL=1`, tous les appels rendent `nil` : MoltenVK signale `VK_ERROR_OUT_OF_POOL_MEMORY` après 3 essais, et l'effacement encodé sans texture ne plante pas et ne déclenche aucune erreur de validation Metal. Seul l'effacement a été vérifié ; une passe de rendu avec un attachement sans texture ne l'est pas. Pendant une perte, R10 ne signale pas cette erreur.

| 6 exécutions par cas | Avant R10 (`630b183e`) | Après R10 (`a3f02d1c`) |
| --- | --- | --- |
| `nextDrawable` entré avant la perte, pas encore revenu | 6/6 | 6/6 |
| encodage actif 20 ms après la perte | 6/6 | 0/6 |
| `nextDrawable` appelé par le fil qui soumet (mode synchrone) | 3/3 | 0/3 |
| perte publiée | après le retour de `nextDrawable` (3 à 4 ms après) | avant, 22 à 25 ms après la perte, environ 940 ms avant ce retour |
| drawable tardif rendu à la couche | 0/6 | 6/6 |

**Coût non mesuré.** Chaque demande de drawable passe maintenant par une file série et une attente notifiée. Aucun banc ne couvre la présentation.

**Limites.** Seul macOS 27.2 est mesuré, sur couche détachée ; M1, M3, iOS et les autres versions restent pour la fin du parcours. R6 reste fermé : O17 vert n'est qu'une de ses conditions.

## 0 octies. R5 : questions à la revue avant toute implémentation

**Fait 1 : R5 suppose R1.** Le retrait de R5 « passe en état de retrait (R1, point 1), puis vide la liste différée » (point 3), et le jeton de présentation est terminé par `MVKSwapchain::destroyNow()` (point 6), deux pièces de R1. R1 n'est pas codé ; l'ordre d'implémentation (§6) place R1 avant R5. Le GO limité ne couvre que R5 et R8.

**Fait 2 : sans R6, aucune séquence valide n'expose ce que R5 change.** Aujourd'hui, `~MVKDevice` attend `_activeEncodings`, `_pendingMTLCommandBufferHandlers` et le job de publication ; `publishLoss()` attend les deux mêmes comptes avant de rapporter la perte. Une application ne peut détruire un device perdu, avec du travail en cours, qu'après qu'une attente a rapporté la perte : les attentes du destructeur sont alors déjà satisfaites. Mesure sur M4, `lib-d4110762`, 6 exécutions par cas (`device-destroy-*`, `2f15b402`) :

| Séquence | `vkDestroyDevice` | Statut |
| --- | --- | --- |
| travail de l'application bloqué, C derrière, perte ; attente hôte ; l'application libère son travail 300 ms après la perte ; l'attente rapporte la perte 5 à 7 ms plus tard ; destruction des objets puis du device | **0,2 à 0,3 ms** | valide |
| même début ; `vkDestroyDevice` 100 ms après la perte, C en attente | **bloque 200 à 210 ms**, jusqu'à la libération | invalide aujourd'hui ; légal une fois la perte rapportée en temps fini (R6) |

- R5 ne change que la seconde ligne, et le jeton de présentation ne corrige, lui aussi, qu'une destruction de swapchain avant la fin de ses présentations, invalide sans perte (§3.13, §5.2).
- Les rouges de R5 ne peuvent donc être, avant R6, que des **témoins de mécanisme en usage aujourd'hui invalide**, comme ceux de R8. O14 et O18 sont des gardes de non-régression : vraisemblablement verts avant comme après.
- R1 est dans la même situation : O2 à O6 échouent aujourd'hui par délai dépassé, faute de R6 (§5).

**Fait 3 : du travail à rouge en usage valide existe hors de R5.** *Reproduit puis corrigé en révision 11 (ci-dessous).* Constat d'origine : `MVKQueryPool::getResults()` avec `VK_QUERY_RESULT_WAIT_BIT` attend sur `_availabilityBlocker`, dont le prédicat lit la perte (`MVKQueryPool.mm:86`, `117`). Mais la publication de la perte (`MVKDevice.mm:4049`) ne le réveille pas. Or une requête encodée passe à « DeviceAvailable » dès l'encodage (`MVKQueryPool.mm:38`), et ne devient jamais disponible si son command buffer est abandonné (`MVKCommandBuffer.mm:1712`), par exemple une soumission préremplie acceptée puis refusée à l'exécution par la perte. Une attente commencée avant la publication peut alors ne jamais rendre la main, contrairement à la section « Lost Device ». Cela relève de R3, sans dépendre de R6. Pour le reproduire, il faut forcer l'ordre « soumission acceptée, perte, exécution refusée » ; aucun crochet actuel ne le permet.

**Options.**
- **A.** R1 puis R5 maintenant, comme mécanismes, avec des oracles témoins en usage aujourd'hui invalide et des gardes de non-régression. C'est la plus grosse refonte de la série (vie du device, sept surcharges de `destroy()`, présentation), sans correctif visible avant R6. Relecteurs upstream : difficile à valider.
- **B.** R5 seul maintenant, les étapes de R1 laissées vides (liste différée vide). Le retrait devient la destruction actuelle, sans attente, déclenchée par la dernière référence. Plus petit, mais le jeton de présentation reste partiel sans `MVKSwapchain::destroyNow()`.
- **C.** Geler R1 et R5 avec R6, et les livrer ensemble quand O17 permettra d'ouvrir R6. En attendant, travailler ce qui a des rouges en usage valide et ce qui bloque R6 : reproduire O17 (`nextDrawable` bloqué), puis R3 (attentes hôte, dont le constat 3).

**Recommandation : C.** Chaque pièce de R1 et R5 n'a d'effet qu'une fois la perte rapportée en temps fini. Les livrer avant R6 ajoute une refonte de la durée de vie que rien d'observable n'exerce, que les oracles ne prouveraient que par des séquences aujourd'hui invalides, et qu'une revue upstream ne pourrait pas juger sur pièces. O17 est la vraie porte de R6.

**Constat 3 reproduit et corrigé (révision 11).** Mode `query-wait-abandoned` (`275b5226`) :
- **Scénario.** Sous préremplissage différé, C réinitialise puis écrit une requête timestamp, encodée dès `vkEndCommandBuffer`. Les soumissions sont asynchrones. Une soumission vide avec fence occupe le fil de la file, car son acquisition Metal est retenue 300 ms. C est acceptée derrière elle, une attente `VK_QUERY_RESULT_WAIT_BIT` démarre, et la perte arrive 100 ms plus tard : l'exécution de C est refusée.
- **Sur `d4110762` : 6/6 rouges.** La perte est rapportée vers 305 ms, et l'attente attend toujours 2 s plus tard.
- **Correctif** (`630b183e`, `MVKQueryPool::getResults()`). L'attente vérifie son prédicat, qui lit déjà la perte, toutes les millisecondes au lieu d'attendre une notification qui ne vient pas.
- **Après : 6/6 verts.** L'attente rend `VK_ERROR_DEVICE_LOST` 0 à 1 ms après le rapport.
- Série générique : même correctif (`df4584d2`) et même oracle (`2a53f65f`).

**Questions à la revue.**
1. R5 : A, B ou C ?
2. Si A ou B : des témoins de mécanisme en usage aujourd'hui invalide suffisent-ils comme oracles rouges de R5, comme pour R8 ?
3. La prochaine passe peut-elle prendre O17, puis R3 (constat 3 d'abord), avant R5 ?
4. **O17** (ajoutée après l'étape 1, §3.13) : sur macOS 27.2, `nextDrawable` n'attend qu'environ 1 s, une fois par couche, même sans délai d'expiration. Un rapport retardé d'autant reste en temps fini, conforme à la spécification ; le seuil de 2 s est celui de la conception. O17 ne peut donc pas être rouge tel qu'écrit. Options :
   - **a.** abaisser le seuil (par exemple 500 ms) et mesurer la latence du rapport avant et après R10 ;
   - **b.** remplacer le critère par celui, déjà cité dans la ligne d'O17, d'un fil d'encodage dans `nextDrawable` au moment de la perte, compté par un swizzle comme les acquisitions (`gAcquiring`) : rouge aujourd'hui dans la recette, vert avec R10 ;
   - **c.** ne plus faire d'O17 une porte de R6 sur macOS 27.2, garder R10 comme défense, et mesurer iOS et les autres versions de macOS avec les essais matériels de fin de parcours.

   Recommandation : **b**, qui garde un oracle réfutable pour R10 sans lui prêter un défaut de correction ; avec **c** pour la porte de R6, puisque le retard mesuré est borné et conforme. L'étape 2 (Vulkan) reste nécessaire pour b : elle doit montrer un encodage dans `nextDrawable` pendant la perte.

## 0 septies. Réponse à la revue de la révision 8 (R8 non clos)

| Constat | Vérifié | Correction (`1deebd18`) | Preuve |
| --- | --- | --- | --- |
| **Progression.** L'invalidation et la copie image vers mémoire ouvrent leur encadrement avant une acquisition Metal qui peut bloquer ; sans R2, sur un Mac sans mémoire unifiée, elle peut empêcher `publishLoss()` de finir | Oui : `beginEncoding()` précédait `getMTLCommandBuffer()`, et `pullFromDevice()` acquérait dans l'encadrement | Le command buffer est acquis **avant** `beginEncoding()` ; `pullFromDevice()` n'acquiert plus, il reçoit le command buffer. L'acquisition peut encore bloquer le fil de l'application, comme avant R8 (cas de R2), mais plus la publication | statique seulement (O20) : pas de Mac sans mémoire unifiée ici. Rouge sur le runtime de `67dd59d4`, vert après ; témoins « acquisition dans l'encadrement » et « `pullFromDevice()` qui acquiert » rouges |
| **Inventaire.** Une de ces opérations peut commencer après la fermeture et commiter sans être comptée : il manque une garde d'admission | Oui : la garde des soumissions (`isLosing()` au début de `execute()`, dans l'encadrement) n'avait pas d'équivalent. L'argument de la révision 8 (l'opération attend sa complétion avant de rendre la main, donc aucun `vkFreeMemory` valide ne la croise) reposait sur une attente sans tranches ; R3 la tranchera et la fera sortir sur perte, et l'opération rendrait alors la main pendant que le GPU écrit encore | Même garde : après `beginEncoding()`, si `isLosing()`, le command buffer est abandonné sans commit, et rien n'est synchronisé. La spécification le permet : après une perte, la mémoire mappée reste accessible, mais son contenu n'est plus défini (section « Lost Device ») | statique seulement (O20) : une vérification `isLosing()` entre `beginEncoding()` et le commit est exigée ; témoin « sans admission » rouge |
| **Allocation tardive.** `freeMemory()` attend aussi pour une mémoire importée après le début de la perte, contrairement à la conception, et ce chemin sert au nettoyage d'un `vkAllocateMemory` échoué | Oui : le test portait sur `isHostMemoryImported()` seul. C'est une **régression en usage valide introduite par la première version de R8** (`67dd59d4`, jamais publiée) : allouer et libérer pendant une perte est permis, et le nettoyage d'un échec est interne | `vkFreeMemory` n'attend que pour une mémoire importée **avec succès, avant le début de la perte** (`isHostMemoryImportedBeforeLoss()`, relevé à la construction) | **GPU, M4** : `free-imported-late-allocation` et `-failed-allocation`, rouges 12/12 sur `67dd59d4` (retour vers 310 ms, à la libération), verts 12/12 sur `1deebd18` (retour en moins de 1 ms) |

- **Ordre mémoire de la garde, corrigé aussi pour les soumissions** (`d4110762`). La garde suit le motif des soumissions : l'encadrement incrémente `_activeEncodings` puis lit la perte ; `markLost()` écrit la perte, puis la publication lit `_activeEncodings`. L'une des deux lectures doit voir l'autre écriture, ce qui exige quatre opérations séquentiellement cohérentes. `isLosing()` était une lecture acquire, compilée en `LDAPR` sur arm64 (vérifié dans la bibliothèque de test) : elle peut être servie avant que l'incrément précédent soit visible des autres cœurs, et les deux côtés pouvaient alors se manquer, pour les soumissions comme pour la nouvelle garde. La lecture est maintenant séquentiellement cohérente (`LDAR`). Aucun oracle ne force cet entrelacement : il dépend du matériel.
- **Limite.** Les deux premiers constats ne s'exécutent que sans mémoire unifiée. Leur correction n'a aucun essai matériel ; sur M4, la non-régression peut seulement montrer que les chemins modifiés ne changent rien quand ils n'encodent rien.
- **Portée : ces deux chemins ne s'exécutent jamais sur Apple Silicon.** L'invalidation ne synchronise que si `!isUnifiedMemoryGPU()` et que la mémoire est « managed » (`MVKDeviceMemory.h:67`) ; la copie image vers mémoire, sous la même condition (`MVKImage.mm:802`). `isUnifiedMemoryGPU()` vient de `MTLDevice.hasUnifiedMemory` (`MVKDevice.mm:2477`), vrai sur tout GPU Apple, et le type « managed » n'est exposé que si `!isAppleGPU` (`MVKDevice.mm:3469`, `3512`). Seul un Mac Intel à GPU discret, ou avec un eGPU, les exécute ; un GPU Intel intégré a la mémoire unifiée. La série PerVertex vise les Macs Apple Silicon (M4, puis M1 et M3) : sur ce périmètre, ces deux constats n'ont aucun effet. La série générique vise MoltenVK upstream, qui supporte encore les Macs Intel. **Décision de l'utilisateur (29 septembre 2026) : la PR précisera que les Macs Intel n'ont pas été testés** ; ces deux chemins n'y ont qu'une preuve statique (O20). Le kit ci-dessous reste disponible si un tel Mac se présente.
- **Kit de qualification** (`MoltenVK/Tests/NonUnifiedHarness/`) : quatre oracles (`host-sync-progress-*`, `host-sync-admission-*`, `b37f617e`) sur trois bibliothèques x86_64 (première version de R8, R8 final, R8 final sans garde d'admission), plus les cinq `free-imported-*`. Il ne rend « QUALIFIED » que si chaque exécution donne le résultat attendu et qu'aucune n'est sautée. Sur M4, ces oracles sortent en « SKIP » ; un mode à vide (`PERVERTEX_HOST_SYNC_DRY=1`) y vérifie seulement les appels Vulkan du test.
- **Non-régression sur `d4110762`** (M4, sous validation Metal pour les oracles) : oracles de perte, 120 conformes et 24 BLOCKER attendus ; les 5 modes `free-imported-*` 30/30 ; suites `loss` 12/12 et `binary` 21/21 ; CTS de l'invalidation (1 704), d'un échantillon de `host_image_copy` (1 833, dont 5 échecs antérieurs, identiques sur `67dd59d4`) et de `external_memory_host` (12), sans aucun écart cas par cas avec `67dd59d4` ; CTS de synchronisation identiques aux passes précédentes. Série générique (`a5be3bae`) : 120 conformes et 24 BLOCKER, `free-imported-*` 30/30, `binary` 7/7, O20 13/13.

## 0 sexies. Réponse au GO limité sur la révision 7 (revue de `f97faeb7`)

| Demande | Réponse | Preuve |
| --- | --- | --- |
| O20 accepterait `beginEncoding()` et `endEncoding()` sans handler de fin | O20 exige maintenant, dans `commitMTLCommandBuffer()`, un handler de fin qui décrémente `_handlersBeforeInventory`, et que toute condition qui l'entoure ne dépende que de l'inventaire ouvert (`55b0f996`). Le décrément doit être dans le bloc donné à `addCompletedHandler`, après la boucle des autres handlers de fin (`ab4e1af7`) | témoins négatifs « handler sans décrément », « décrément avant les autres handlers » et « handler seulement s'il y a d'autres handlers » : rouges |
| O20 pourrait manquer un appel dans une fonction libre | O20 analyse chaque définition de fonction, membre ou libre, en ligne dans une classe ou non, dans les sources et les en-têtes (`55b0f996`). Il échoue aussi sur tout `[x commit]` direct hors de `commitMTLCommandBuffer()`, sauf sur un residency set (`86ea6506`) : un tel commit échapperait à l'inventaire sans passer par un site classé | témoins « fonction libre qui commite » et « commit direct » : rouges. Les 9 contrôles (actuel vert, `f97faeb7` rouge, 7 mutations rouges) sont rejoués par un script gardé avec les preuves, sur les deux séries |
| Prouver que `vkFreeMemory` attend la fin de ce handler | Nouveau mode `free-imported-waits-slow-handler` : chaque handler de fin de MoltenVK démarre 200 ms en retard. Le travail GPU de C finit quelques ms après la libération du travail de l'application ; l'inventaire ne décompte C qu'à la fin de son handler. `vkFreeMemory` doit donc rendre la main au moins 200 ms après la libération (`5ff46293`) | Après R8 : sans retard, retour 8 à 15 ms après la libération ; retard 200 ms, 210 à 221 ms ; retard 400 ms, 409 à 417 ms. Avant R8 : 301 à 305 ms **avant** la libération. Le retard est inséré avant le handler : la mesure prouve que `vkFreeMemory` attend l'exécution du handler, pas la fin du GPU. Qu'il en attende la **fin** est un fait statique, vérifié par O20 : le décrément suit les autres handlers de fin ; seul le compte `_pendingMTLCommandBufferHandlers`, qui ne touche aucune mémoire de l'application, est rendu après lui |
| O11 doit forcer l'entrelacement de la revue | La première version retenait C **dans** le commit Metal, donc après que `commitMTLCommandBuffer()` avait décidé de compter C. Le témoin négatif (inventaire fermé à `markLost()`) passait, sans rien discriminer. C est maintenant retenu à la création de son premier encodeur Metal, avant ce choix, et le verdict exige que la retenue ait eu lieu (`74e5058c`) | Témoin négatif : 6/6 rouges. `vkFreeMemory` rend la main 151 à 160 ms après le départ (perte vers 100 ms), pages vides ; puis C plante (`SIGSEGV`) dans `MVKCmdFillBuffer::encode` en liant le `MTLBuffer` libéré. Avant R8 : 6/6 rouges, même plantage. Après R8 : 6/6 verts. Ces rouges sont des **témoins de mécanisme**, pas un défaut en usage valide aujourd'hui : aucune attente n'a rendu la perte avant `vkFreeMemory`, ce qui reste invalide sans R6. Ils montrent ce que produirait, sans R8, la séquence que R6 rendra légale |
| Le chemin sans mémoire unifiée reste sans essai matériel sur M4 | Noté. Sur M4 (mémoire unifiée), `invalidateMappedMemoryRanges()` et `copyImageToMemory()` n'encodent aucune synchronisation : la variante (2) d'O11 n'est pas exécutable ici. O20 est la seule preuve de leur encadrement | aucune exécution ; à faire sur un Mac Intel avec GPU discret, non disponible |

## 0 quinquies. Réponse au NO-GO sur la révision 6 (revue de `91bcd0d4`)

| Constat | Vérifié | Correction | Section |
| --- | --- | --- | --- |
| R5 : le callback de présentation exécute `endPresentation()` sans retenir le device ; le retrait peut le détruire pendant ce callback | Oui : le jeton de la révision 6 arbitrait qui termine la présentation, pas la vie du device pendant ce travail | Le compte de vie devient une paire **forte/faible**. Le callback tente de **promouvoir** sa référence faible ; s'il réussit, le retrait ne peut pas commencer avant qu'il la rende ; s'il échoue, le retrait a commencé et termine lui-même la présentation. O15 force les deux ordres | R5, §5 |
| R8 : d'autres chemins que les soumissions appellent `commitMTLCommandBuffer()` hors de l'encadrement, dont l'invalidation de mémoire et la copie image vers mémoire | Oui : 7 sites, dont 3 hors encadrement ; 2 d'entre eux peuvent écrire dans des pages importées (§3.14) | Ces 2 chemins sont encadrés comme des encodages, de l'acquisition au commit ; les 3 autres n'accèdent à aucune mémoire, ce que vérifie un contrôle statique nouveau (O20) qui classe chaque site d'appel | R8, §3.14, §5 |

## 0 quater. Réponse au NO-GO sur la révision 5 (revue de `0ac8e6f5`)

| Constat | Correction | Section |
| --- | --- | --- |
| R8 : l'inventaire relevé à `markLost()` manque le travail d'un encodage commencé avant, qui commite après | L'inventaire est **fermé à la publication**, une fois `_activeEncodings` revenu à zéro : plus aucun encodage ne peut alors commiter du travail d'application. `vkFreeMemory` attend cette fermeture, puis le retrait de tout ce qui a été commité avant elle | R8 |
| O11 doit forcer cet entrelacement | O11 retient le commit de C (crochet de commit existant, retardé) pour qu'il ait lieu **après** `markLost()` et avant la fin de l'encodage ; témoin négatif : inventaire relevé à `markLost()` | §5 |
| R4 avant la porte de R6 | L'ordre d'implémentation place R4 et O6 avant R6 | §6 |
| Oracles de progression et d'ordre des handlers | O18 force les deux ordres entre handlers « scheduled » et « completed » ; nouvel oracle de progression O19, entrelacements variés, toutes les attentes bornées et chaque device retiré une fois | §5 |
| Jeton de présentation, correctif isolé | **Non implémenté : prémisse non vérifiée.** En usage valide, les présentations se terminent aujourd'hui (mesuré) ; le défaut n'apparaît qu'en détruisant le swapchain avant la fin de ses présentations, ce que Vulkan interdit hors perte et que R6 rendra légal. Le jeton reste une pièce de R5, avec ses oracles | R5, point 6 ; §5.2 |
| O17 | Toujours sans reproduction fiable du blocage de `nextDrawable` ; R6 reste fermé tant qu'O17 n'est pas vert | §5 |

## 0 ter. Réponse au NO-GO sur la révision 4 (revue de `a253c42c`)

| Constat | Vérifié | Correction | Section |
| --- | --- | --- | --- |
| Le fil série commun à la réserve de command buffers et à `nextDrawable` peut créer un blocage circulaire, même sans perte | Oui : une acquisition de command buffer se retrouvait derrière une attente de drawable, et inversement | Deux files d'acquisition distinctes, jamais partagées : une par file Metal pour les command buffers, une par `CAMetalLayer` pour les drawables. Graphe des attentes donné : aucune acquisition n'attend un encodage | R2, R10 |
| R5 doit protéger séparément les handlers « scheduled » et « completed » | Oui : `commitMTLCommandBuffer()` enregistre jusqu'à deux handlers Metal, déjà comptés un par un ; la révision 4 parlait à tort d'un « handler unique » | Une référence de vie par handler Metal enregistré, rendue par ce handler comme dernier geste | R5 |
| Une présentation sans callback peut bloquer la file de retrait des autres devices | Oui, et **mesuré** : après la fin forcée de MoltenVK, les handlers de présentation en attente ne sont **jamais** appelés (§3.13) | Plus de phase 2. Le handler de présentation ne tient qu'un jeton détachable (motif de R9) ; le retrait fait lui-même, une seule fois, la fin de présentation que le handler ne fera pas. **La file de retrait n'attend jamais** | R5 |
| R8 recommandait (b), mais R6, R7 et O11 décrivaient (a) ; (b) déplace le blocage vers `vkFreeMemory` | Oui | **La conception adopte (b)**, et R6, R7 et O11 sont réécrits en ce sens. Le blocage déplacé est décrit et borné à son cas. (a) reste une variante nommée | R6, R7, R8, O11 |
| O15 et O17 pouvaient rester « non couverts » | Oui | Plus d'échappatoire : O15 et O17 sont **obligatoires** avant R6. La sonde montre qu'une `CAMetalLayer` hors fenêtre fournit des drawables et rappelle les handlers ; O17 doit d'abord reproduire un `nextDrawable` bloqué | §5 |

## 0 bis. Réponse au NO-GO sur la révision 3 (revue de `7838e797`)

| P1 ou demande | Vérifié | Correction | Section |
| --- | --- | --- | --- |
| R2 peut entrer dans une acquisition Metal bloquante entre la restitution du crédit MoltenVK et celle de la place par Metal | Oui. Mesuré (§3.12) : Metal rend la place **après** le retour du handler de fin, jamais pendant (80 essais sur 80, M4 Pro). Et l'application peut prendre la place libérée sur la file exportée | **Aucun fil d'encodage ni de l'application n'appelle plus l'acquisition Metal** : un fil d'acquisition par file Metal tient une réserve de command buffers pré-acquis ; l'encodage attend par tranches et sort sur perte | R2, §3.12 |
| `nextDrawable` peut bloquer un encodage que R6 attend | Oui (§3.11) : jusqu'à `imageCount` × 1 s par défaut, **sans borne** si l'application désactive `allowsNextDrawableTimeout` sur sa couche | Acquisition du drawable par le même fil d'acquisition ; l'encodage attend par tranches et sort sur perte | R10, §3.11 |
| Le retrait du device peut attendre un callback de présentation que seule la destruction différée du swapchain débloquerait | Oui : compter les handlers de présentation comme condition de départ du retrait crée le cycle | Retrait en **deux phases** : départ exclusif, vidage de la liste différée (qui force la fin des présentations), puis seulement l'attente des handlers de présentation, sur le fil de retrait | R5 (**remplacé en révision 5** : la sonde §3.13 montre que la fin forcée supprime ces handlers) |
| Les chemins de destruction directe et différée n'ont pas de transition exclusive | Oui : cinq compteurs lus séparément laissent deux fils conclure « tout est à zéro » | **Un seul compte de vie atomique** : l'application et chaque travail en cours en tiennent une référence ; le fil dont `fetch_sub` rend 1 est le seul à retirer | R5 |
| Oracles : démarrer les attentes avant la perte | Fait pour `-idle` et `-query` (`bc6bc7ad`) | O1, O5, O9 l'exigent | §5 |
| Oracles : mieux vérifier la conservation des ressources, les descriptor pools, l'ABA | — | O2 : référence faible **et** contenu écrit par C ; O6 : crochet d'état du pool ; O12 : chaque attente jugée, 10 tours (`bc6bc7ad`), témoin négatif | §5 |
| R8 abandonne le temps fini avec de la mémoire hôte importée | Oui, explicitement | Trois options chiffrées, une recommandation ; décision à la revue | R8, §7 |
| Devices vivants partageant une file Metal | À trancher | Recommandation : une file Metal par device vivant | R2, §7 |

## 0. Réponse au NO-GO du 29 septembre (revue de `6dee5d90`)

| Constat d'Astra | Vérifié dans le code | Correction | Section |
| --- | --- | --- | --- |
| Renommer les sept `destroy()` en `destroyNow()` sans changer leurs appels à la base crée une récursion | Oui : chaque corps appelle `Base::destroy()`, qui deviendrait le `destroy()` `final`, donc de nouveau `destroyNow()`. La phrase « leur corps ne change pas » de la révision 2 était **fausse** | Chaque appel à la base devient `Base::destroyNow()` ; garde de réentrée ; contrôle statique | R1, §3.1 |
| Le quota par `MVKQueue` ignore que plusieurs devices partagent une file Metal | Oui : `MVKQueueFamily::getMTLCommandQueue()` met les files en cache par device physique, pour tous les devices et d'un device au suivant ; `MVKQueue` ne la retient pas (`MVKQueue.mm:34-47`, `388`) | Compte par file Metal, dans la famille ; une file qui porte le travail bloqué d'un device perdu sort du cache ; `MVKQueue` retient sa file ; partage entre devices vivants : question ouverte | R2, §3.6 |
| Le retrait différé ne protège pas la mémoire hôte importée | Oui : `newBufferWithBytesNoCopy: … deallocator: nil` sur le pointeur de l'application (`MVKDeviceMemory.mm:259`) ; après `vkFreeMemory`, l'application peut libérer ses pages, ce que la spécification autorise dès qu'une attente a rendu `VK_ERROR_DEVICE_LOST` | Aucun report ne peut couvrir des pages que MoltenVK ne possède pas : publication anticipée **désactivée** pour un device qui avait de la mémoire hôte importée au début de la perte | R8, §3.7 |
| Ni tous les callbacks de présentation | Oui : `addPresentedHandler` (`MVKImage.mm:1745`) n'est compté nulle part ; il relâche l'image et signale des sémaphores et fences que l'application a pu détruire | Handlers de présentation comptés dans R5 ; hypothèse sur Metal écrite | R5, §3.9 |
| Les attentes de résultats de requêtes et de présentation survivent à la publication | Oui : `MVKQueryPool::getResults()` avec `VK_QUERY_RESULT_WAIT_BIT` (`MVKQueryPool.mm:86`) et `MVKSwapchain::waitForPresent()` (`MVKSwapchain.mm:248`) attendent sans condition de perte | Inventaire complet des attentes hôte ; chacune attend par tranches et sort sur perte publiée | R3, §3.8 |
| Durée de vie des listeners timeline | Oui : un listener sur un événement importé peut ne jamais rappeler ; il retient le sémaphore, dont le destructeur utilise le device. De plus, il identifie l'attente par l'adresse d'un objet de pile (**ABA**, trouvé à la relecture) | Le listener ne retient plus que un jeton détachable ; il n'est pas compté dans R5 | R9, §3.9 |
| Quarantaine des descriptor pools | Oui : `vkResetDescriptorPool` rembobine tout l'allocateur (`MVKDescriptorSet.mm:2231`) : une quarantaine par région n'y survit pas | Pendant une perte, le pool est épuisé jusqu'à sa destruction différée | R4, §3.10 |

## 1. Le problème

Le reproducteur `external-queue-wait` (`PerVertexLossTests.mm`) reste `BLOCKER`. Voici son déroulé :
1. L'application commit, sur la `MTLCommandQueue` exportée de la file B, un command buffer X. Il attend un `MTLSharedEvent` que MoltenVK ne connaît pas.
2. Elle soumet C sur la file B, derrière X.
3. Le device est perdu.
4. MoltenVK ne rapporte la perte qu'après la fin des handlers de C. Or ceux-ci attendent X, donc le signal de l'application : l'attente hôte rend `VK_TIMEOUT`.

La conception doit tenir deux garanties à la fois :
- **G1.** Les attentes hôte rendent `VK_ERROR_DEVICE_LOST` en temps fini, même si l'application ne libère jamais son travail.
- **G2.** Rien de ce qu'utilise le travail commité encore en vol n'est libéré avant son retrait. Cela vaut pour le GPU (ressources Metal) comme pour les handlers CPU (objets MoltenVK).

Deux voies sont écartées, pour les raisons déjà données au rapport :
- publier la perte après un délai borné, sans rien retenir ;
- créer tous les command buffers à références retenues.

## 2. Ce que la proposition précédente manquait

| Point demandé | Constat dans le code | Conséquence pour la proposition précédente |
| --- | --- | --- |
| `destroy()` qui libère avant sa classe de base | 7 surcharges libèrent des objets Metal **avant** d'appeler la classe de base (§3.1) | I1 prévoyait d'intercepter dans `MVKVulkanAPIDeviceObject::destroy()`. Ce point n'est atteint qu'**après** ces libérations. **Faux.** |
| Acquisition Metal bloquante sur une file saturée | `commandBufferWithDescriptor:` bloque quand toutes les places de la file sont prises (§3.2). Un encodage peut s'y bloquer pour toujours | I4 posait que les encodages en cours sont bornés. **Faux** : publier après eux peut ne jamais finir |
| Destruction du device depuis un callback | Le dernier handler supprimerait le device dans un callback Metal : il y relâcherait la `MTLCommandQueue` de ce même handler, le `MTLDevice`, et ferait un `dispatch_sync` (§3.5) | Risque cité, sans solution. Il en faut une |
| Réutilisation des pools pendant la perte | Command buffers, descriptor sets, requêtes, allocations temporaires (§3.4) | Signalée, non traitée |
| *Trouvé en plus* : attentes de complétion bloquantes | `vkQueueWaitIdle`, `vkDeviceWaitIdle`, `vkInvalidateMappedMemoryRanges` et `vkCopyImageToMemoryEXT` appellent `waitUntilCompleted` (§3.3) | G1 resterait faux pour ces appels, même avec une publication en temps fini |
| *Trouvé en plus* : la surface du swapchain | `MVKSwapchain::destroy()` écrit dans `_surface`, que le swapchain ne retient pas (§3.1) | Un swapchain différé toucherait une surface détruite entre-temps |
| *Trouvé en plus* : le job de publication de la perte | `publishLoss()` s'exécute sur `_lossPublisher` après `markLost()`, puis commit un command buffer de secours (§3.2) | Un device supprimé dès que les compteurs sont à zéro pourrait l'être sous ce job |

## 3. Faits relevés

### 3.1 Surcharges de `destroy()`

`MVKReferenceCountingMixin::release()` (`Utility/MVKBaseObject.h:164`) appelle `BaseClass::destroy()` de façon statique, c'est-à-dire `delete this`. Les surcharges suivantes libèrent donc des objets Metal avant la suppression différée :

| Surcharge | Ce qu'elle libère avant la classe de base |
| --- | --- |
| `MVKBuffer::destroy()` (`MVKBuffer.mm:232`) | `detachMemory()` : `MTLBuffer` dédié, ensemble des ressources vivantes, résidence, lien à la mémoire |
| `MVKBufferView::destroy()` (`MVKBuffer.mm:334`) | texture de la vue, ressources vivantes, résidence |
| `MVKImageView::destroy()` (`MVKImage.mm:2393`) | plans de la vue, avec leurs textures |
| `MVKSampler::destroy()` (`MVKImage.mm:2690`) | `MTLSamplerState` |
| `MVKSwapchainImage::destroy()` (`MVKImage.mm:1548`) | détache le swapchain |
| `MVKPresentableSwapchainImage::destroy()` (`MVKImage.mm:1836`) | drawable, texture headless |
| `MVKSwapchain::destroy()` (`MVKSwapchain.mm:648`) | retire le swapchain de sa surface, force la fin des présentations, détruit les images présentables |

`MVKMetalCompiler::destroy()` n'est pas un objet du device : il n'est pas concerné. `MVKSwapchain` garde un `MVKSurface*` (`MVKSwapchain.h:129`) sans le retenir.

Appels à la base dans ces corps : `MVKResource::destroy()` (buffer), `MVKVulkanAPIDeviceObject::destroy()` (vue de buffer, vue d'image, sampler, swapchain), `MVKImage::destroy()` (image de swapchain, `MVKImage` n'ayant pas de surcharge), `MVKSwapchainImage::destroy()` (image présentable). Tous résolvent vers `MVKVulkanAPIDeviceObject::destroy()` si celui-ci devient le point d'entrée `final` : un renommage seul boucle.

### 3.2 Acquisitions de command buffers Metal

Deux sites acquièrent un command buffer Metal :
- `MVKQueue::getMTLCommandBuffer()` (`MVKQueue.mm:220`), sur les files du device. Elles sont créées avec `maxActiveMetalCommandBuffersPerQueue` places (`MVKQueue.mm:43-44`). C'est le site qui peut bloquer.
- `MVKDevice::releaseSemaphoreWaitsAfterLoss()` (`MVKDevice.mm:4073`), sur la file de secours du device physique (`MVKDevice.mm:3821`, 64 places par défaut). Cette file ne porte jamais de travail de l'application, seulement les signaux qui libèrent les attentes Metal après une perte ; ses command buffers ne font que signaler des événements, donc elle ne sature pas. Elle n'a pas besoin de R2. Ses handlers sont comptés par `commitMTLCommandBuffer()`, donc elle entre dans R5.

Les appelants de `MVKQueue::getMTLCommandBuffer()` :
- pendant un encodage de soumission, compté dans `_activeEncodings` : `getActiveMTLCommandBuffer()` et `continueOnNewMTLCommandBuffer()` ;
- sur le fil de l'application : `vkBeginCommandBuffer` avec préremplissage (`MVKCommandBuffer.mm:188`). Le command buffer prérempli garde sa place jusqu'à sa fin, ou jusqu'à son abandon ;
- `waitIdle()` (`MVKQueue.mm:204`), l'acquisition d'image (`MVKImage.mm:1615`), la présentation (`MVKQueue.mm:910`) ;
- sur macOS sans mémoire unifiée : `vkInvalidateMappedMemoryRanges` (`MVKDeviceMemory.mm:110`) et `vkCopyImageToMemoryEXT` (`MVKImage.mm:804`).

**Mesuré** (`build/astra/r3-slots`, `build/astra/r5-abandon-probe`, M4 et macOS 27.2) :
- sur une file de 4 places, la cinquième acquisition bloque tant que quatre command buffers gardent leur place ;
- un command buffer relâché sans `enqueue` ni `commit` rend sa place ;
- un command buffer mis en file (`enqueue`), puis relâché sans commit, garde sa place sans validation, et fait échouer une assertion de la validation de l'API (`enqueued-release-*.out`). MoltenVK ne le fait jamais.

Les command buffers bloqués derrière X gardent leur place. Les command buffers que l'application commit elle-même sur la file exportée en prennent aussi.

### 3.3 Attentes de complétion bloquantes

Les attentes suivantes n'ont pas de borne quand le travail ne se termine jamais :
- `MVKQueue::waitIdle()` : `waitUntilCompleted` (`MVKQueue.mm:206`). Elle sert `vkQueueWaitIdle` et `vkDeviceWaitIdle` ;
- `MVKDevice::invalidateMappedMemoryRanges()` (`MVKDevice.mm:5102`) ;
- `MVKImage::copyImageToMemory()` (`MVKImage.mm:823`).

Seul `continueOnNewMTLCommandBuffer()` attend par tranches de 1 ms, en surveillant `isLosing()`.

### 3.4 Handlers et objets qu'ils touchent

| Handler | Objets touchés |
| --- | --- |
| `MVKQueue::getMTLCommandBuffer` (`MVKQueue.mm:226`) | la file, le device (`handleMTLCommandBufferError`) |
| `commitActiveMTLCommandBuffer` (`MVKQueue.mm:681`) | la soumission (qui retient fence et sémaphores), la file, le device |
| `continueOnNewMTLCommandBuffer` (`MVKQueue.mm:596`) | un sémaphore de dispatch, retenu par le bloc |
| présentation (`MVKQueue.mm:937`, `MVKImage.mm:1677`, `1703`) | la soumission de présentation ; l'image, la fence et le drawable, retenus ; `_swapchain`, **non retenu** |
| `pullFromDeviceOnCompletion` (`MVKImage.mm:450`) | le plan d'image et la mémoire mappée |
| `keepPerVertexScratchResident` (`MVKCommandBuffer.mm:838`) | le device, le scratch (capturé par valeur) |
| `getTempMTLBuffer`, `vkCmdUpdateBuffer` (`MVKCommandBuffer.mm:1560`, `MVKCmdTransfer.mm:1795`) | l'allocation et son `MVKMTLBufferAllocationPool`, qui appartient au pool de commandes |
| `finishQueries` (`MVKCommandBuffer.mm:1710`) | les pools de requêtes |
| `MVKCmdTransfer.mm:544`, `590`, `706`, `MVKCommandBuffer.mm:1678` | des objets Metal retenus par le bloc |
| écouteurs `MTLSharedEvent` des attentes timeline (`MVKSync.mm:298`) | le sémaphore, retenu, dont le destructeur utilise le device |

Aucun handler ne capture un `MVKCommandBuffer`, un `MVKCommandEncoder` ou une `MVKCommand`.

**Pools :**
- `vkResetCommandPool` réinitialise ses command buffers et vide les pools de types de commandes (`MVKCommandPool.mm:34`, `85`). Il ne vide pas le pool d'encodage.
- Les allocations temporaires ne reviennent au pool d'encodage que par leur handler. L'oracle `7758838b` prouve qu'elles y reviennent exactement une fois.
- Les descriptor sets libérés rendent leur région d'argument buffer, qu'une allocation suivante réutilise.

### 3.5 Destruction du device

Deux points bloquent la destruction dans un callback :
- `~MVKDevice` (`MVKDevice.mm:5832`) attend `_activeEncodings` et `_pendingMTLCommandBufferHandlers`, puis détruit les files : leurs `MTLCommandQueue` sont relâchées ;
- `publishLoss()` (`MVKDevice.mm:4029`) attend `_pendingMTLCommandBufferHandlers` : c'est la cause directe du `BLOCKER`.

Si le dernier handler supprimait le device, cette suppression s'exécuterait dans un callback Metal de l'une de ces files. Apple ne documente pas qu'on puisse y relâcher la `MTLCommandQueue` ou le `MTLDevice` : Metal pourrait attendre son propre fil de complétion.

### 3.6 Files Metal partagées

- `MVKQueueFamily::getMTLCommandQueue()` (`MVKQueue.mm:34-47`) garde une `MTLCommandQueue` par index de file, dans la famille du **device physique**. Tous les `VkDevice` créés sur ce device physique, en même temps ou l'un après l'autre, reçoivent la même file pour le même index. Le cache évite la lenteur de création des files Metal (commentaire du code : des délais de 15 s).
- `MVKQueue` ne la retient pas (`MVKQueue.mm:388`).
- Le nombre de places est fixé une fois, à la création de la file.
- **Reproduit** (`shared-queue-block`, §5.1) : les deux devices exportent la même `MTLCommandQueue`. Un device sain qui la partage avec un device perdu est bloqué de deux façons :
  - quand la file est pleine, dans l'acquisition d'un command buffer Metal ;
  - même avec des places libres (témoin à 64 places), dans l'**ordre d'exécution** de la file : son travail passe derrière celui de l'autre device.
- Le second blocage ne dépend ni de la perte ni des places : deux devices vivants qui partagent une file Metal se ralentissent ou se bloquent l'un l'autre. Aucun compte de places ne le résout.

### 3.7 Mémoire hôte importée

- `VK_EXT_external_memory_host` : `MVKDeviceMemory` garde le pointeur de l'application (`MVKDeviceMemory.mm:330-335`), et crée son `MTLBuffer` par `newBufferWithBytesNoCopy:… deallocator: nil` (`MVKDeviceMemory.mm:259`). Il ne libère pas ces pages (`MVKDeviceMemory.mm:296`).
- La spécification (section *Lost Device*) dit que, pour décider si une ressource est encore utilisée par le device, un retour `VK_ERROR_DEVICE_LOST` équivaut à `VK_SUCCESS`. Après le rapport de la perte, l'application peut donc appeler `vkFreeMemory`, puis libérer ses pages.
- Un travail encore en vol qui écrit dans ce buffer écrirait alors dans une mémoire que l'application a rendue. Retenir le `MTLBuffer` n'y change rien.

### 3.8 Attentes hôte

La spécification (section *Lost Device*) exige que `vkDeviceWaitIdle`, `vkQueueWaitIdle`, `vkWaitForFences`, `vkAcquireNextImageKHR` avec un délai maximal, et `vkGetQueryPoolResults` avec `VK_QUERY_RESULT_WAIT_BIT` rendent la main en temps fini après une perte, avec `VK_SUCCESS` ou `VK_ERROR_DEVICE_LOST`.

| Attente | Code | Sort sur perte publiée aujourd'hui ? |
| --- | --- | --- |
| `vkWaitForFences`, `vkWaitSemaphores`, attente d'événement | `MVKFenceSitter`, `MVKSemaphoreImpl` inscrits au device (`_awaitingSemaphores`), `getHostWaitResult()` | oui, dès la publication |
| `vkQueueWaitIdle`, `vkDeviceWaitIdle` | `MVKQueue::waitIdle()` : variable de condition `_execQueueConditionVariable` (`MVKQueue.mm:201`), puis `waitUntilCompleted` (`MVKQueue.mm:206`) | **non** : bloque derrière le travail bloqué |
| `vkGetQueryPoolResults` + `WAIT_BIT` | `_availabilityBlocker.wait` (`MVKQueryPool.mm:86`), sans condition de perte | **non** |
| `vkWaitForPresentKHR`, `vkWaitForPresent2KHR` | `_currentPresentIdCondVar.wait_for` (`MVKSwapchain.mm:248`), sans condition de perte | **non** (hors de la liste de la spécification, mais `VK_ERROR_DEVICE_LOST` est un de ses retours) |
| `vkAcquireNextImageKHR` | ne bloque pas côté hôte : signale la fence ou le sémaphore quand l'image se libère (`MVKSwapchain.mm:77-103`) | l'attente suivante de la fence est couverte par la première ligne |
| `vkInvalidateMappedMemoryRanges`, `vkCopyImageToMemoryEXT` (macOS sans mémoire unifiée) | `waitUntilCompleted` (`MVKDevice.mm:5102`, `MVKImage.mm:823`) | **non** |
| attentes internes | encodage sur sémaphore émulé (`MVKSync.mm:227`, annulé par `markLost()`), continuation (`MVKQueue.mm:600`, par tranches), compilation (`MVKSync.mm:553`, bornée par la configuration) | oui, ou bornées |

**Reproduit** : `external-queue-wait-idle` et `external-queue-wait-query` (§5.1).

### 3.9 Callbacks hors command buffer

- **Handler de présentation** (`[CAMetalDrawable addPresentedHandler:]`, `MVKImage.mm:1745`). Il est ajouté depuis le handler « scheduled » d'une présentation, qui est compté. Lui-même ne l'est pas. Il appelle `endPresentation()`, qui relâche l'image et signale les sémaphores et fences en attente d'acquisition. Si l'application les a détruits après la perte (R1 les diffère), et que le device est retiré avant ce handler, ce dernier touche des objets supprimés.
- **Listener `MTLSharedEvent`** des attentes timeline (`MVKTimelineSemaphoreMTLEvent::registerWait()`, `MVKSync.mm:289-306`).
  - Il retient le sémaphore et le relâche à la fin du bloc. Le destructeur du sémaphore utilise le device quand ses attentes Metal ont été libérées après une perte (`_isLossReleased`, `MVKSync.mm:331-333`).
  - Sur un événement importé, la valeur attendue peut ne jamais être atteinte : le listener ne rappelle jamais.
  - Il identifie l'attente par l'adresse du `MVKFenceSitter`, un objet de pile de `vkWaitSemaphores()` (`MVKSync.mm:515`). `unregisterWait()` le retire de `_sitters` au retour, mais le listener reste inscrit chez Metal. Une attente suivante, au même endroit de la pile, a la même adresse : l'ancien listener la réveille. `vkWaitSemaphores()` rend alors `VK_SUCCESS` sans relire la valeur (`MVKSync.mm:525-526`). **Défaut actuel, sans perte**, à reproduire (`timeline-listener-aba`, §5.1).
- **Handlers de compilation** (`MVKShaderModule.mm:586`, `725`, `MVKPipeline.mm:3613`, `3648`) : ils ne touchent que leur `MVKMetalCompiler`, dont la destruction attend déjà la fin de la compilation (`MVKSync.mm:582`). Inchangés.

### 3.10 Réinitialisation des descriptor pools

`MVKDescriptorPool::reset()` (`MVKDescriptorSet.mm:2231`) vide les listes libres et remet à zéro les allocateurs à bosse (`_cpuBufferUsed`, `_gpuBufferUsed`, `_numAllocatedDescriptorSets`). `freeDescriptorSets()` (`MVKDescriptorSet.mm:2203`) rend les régions aux listes libres. Une quarantaine qui ne toucherait qu'aux listes libres ne survivrait pas à un reset.

### 3.11 Drawables

- `MVKPresentableSwapchainImage::getCAMetalDrawable()` (`MVKImage.mm:1632-1656`) appelle `[CAMetalLayer nextDrawable]` jusqu'à `imageCount` fois. Il est appelé à l'encodage, quand une commande utilise la texture d'une image de swapchain (`getMTLTexture()`, `MVKImage.mm:1660`).
- MoltenVK ne règle pas `allowsNextDrawableTimeout` : par défaut, chaque appel rend `nil` au bout de 1 s. L'encodage peut donc attendre `imageCount` secondes. La couche appartient à l'application (`VK_EXT_metal_surface`), qui peut désactiver ce délai : l'attente n'aurait alors pas de borne. **Mesure contraire sur macOS 27.2** (§3.13, O17, `0d216bcb`) : dans la seule recette qui fait attendre `nextDrawable`, l'appel rend un drawable au bout d'environ 1 s même quand ce délai est désactivé (9/9 sur couche détachée, 6/9 en fenêtre). Les autres versions de macOS et iOS ne sont pas mesurées.
- Les drawables sont retenus jusqu'à la fin de leur présentation. Si les présentations attendent le travail bloqué, `nextDrawable` attend aussi.
- Les signalers d'acquisition retiennent déjà leur sémaphore et leur fence (`track()`, `MVKImage.mm:1570`), et le handler de présentation retient l'image (`beginPresentation()`). Le seul objet que ces callbacks touchent sans le retenir est le **device**, par les destructeurs que déclenchent leurs derniers `release()`.

### 3.12 Quand Metal rend une place

Sonde Metal seule `MetalSlotReleaseProbe.mm` (`build/astra/r6-slot-release/`, M4 Pro, macOS 27.2, avec et sans validation, 4 exécutions de 20 tours) :
- une file d'**une** place ; un command buffer A commité ; depuis le handler de fin de A, un autre fil tente d'acquérir B, et le handler attend 200 ms avant de rendre la main ;
- **B n'est jamais acquis pendant le handler** (0/80), et toujours peu après son retour (80/80, entre 0,1 et 2,2 ms plus tard).

Conséquence :
- un crédit que MoltenVK rendrait depuis un handler de fin précède toujours la restitution de la place par Metal ;
- une acquisition qui suit ce crédit peut donc bloquer. Normalement, c'est seulement le temps que les handlers finissent. Mais si l'application prend la place libérée sur la file exportée, l'attente devient illimitée ;
- la marge de la révision 3 ne ferme pas cette fenêtre, d'où la délégation de l'acquisition (R2).

### 3.13 Présentation, mesurée

Sonde Metal seule `MetalPresentationProbe.mm` (`7e7d53e8`, `build/astra/r7-presentation/`, M4 Pro, macOS 27.2, avec et sans validation). Chaque mode est lancé deux fois : couche détachée de toute fenêtre, puis dans une fenêtre à l'écran.

| Mesure | Détachée | Fenêtre |
| --- | --- | --- |
| drawables fournis, présentation depuis le handler « scheduled » comme MoltenVK | 6/6 ; handlers de présentation 6/6, sans heure de présentation | 6/6 ; handlers 6/6, avec heure de présentation (3 à 5 sur 6) |
| présentations en attente derrière du travail bloqué, **puis changement de taille** comme `forceUnpresentedImageCompletion()`, puis signal | handlers **0/2**, ni après le changement, ni dans les 5 s suivant le signal | **0/2** |
| témoin : les mêmes présentations, signal **sans** changement de taille | handlers 2/2 | 2/2 |
| 3 drawables retenus (`maximumDrawableCount = 3`), 4ᵉ `nextDrawable` | nouveau drawable (texture et IOSurface distinctes) en moins de 10 ms, avec ou sans délai | idem |
| 3 drawables en présentation derrière du travail bloqué, 4ᵉ `nextDrawable` | nouveau drawable en 1 ms au plus | idem |
| **usage valide** : travail terminé (`waitUntilCompleted`), présentation en attente du seul affichage, **puis changement de taille** | handlers 3/3 | handlers **3/3**, alors que 1 ou 2 présentations sur 3 étaient encore en attente au changement (`v6`) |

- **Conséquence pour R5.** La phase 2 de la révision 4 (« attendre les handlers de présentation après la fin forcée ») attendait des callbacks que la fin forcée **supprime**. Elle aurait bloqué pour toujours.
- **Pas de défaut en usage valide aujourd'hui** (correction de la révision 5, qui en annonçait un). La fin forcée ne supprime les callbacks que des présentations encore **derrière du travail non terminé**. Or Vulkan interdit, hors perte, de détruire un swapchain avant la fin de ses présentations. Avec du travail terminé, même en attente d'affichage, les handlers sont appelés.
- **Au niveau Vulkan** (`d5ba4e27`, couche détachée, `lib-d24159ce`, `build/astra/r7-present-vulkan-d24159ce/`) :
  - `present-scheduled-after-destroy` et `present-destroy-race` détruisent le swapchain après `vkQueueWaitIdle`, avec les handlers de MoltenVK retardés de 300 ms ou de 0 à 3 ms : **8/8 verts**. Metal exécute les handlers « scheduled » d'un command buffer avant de le déclarer terminé ;
  - `present-pending-destroy` détruit le swapchain pendant que ses présentations attendent du travail bloqué, ce qui est **invalide hors perte** : **4/4 plantages** (139) dans `MVKSwapchain::beginPresentation()`, sur le `_swapchain` nul d'une image détachée avant que son handler « scheduled » ne s'exécute (rapports de plantage conservés).
- **Ce que R6 change.** Une perte publiée en temps fini rendra ce scénario légal : l'application recevra `VK_ERROR_DEVICE_LOST` pendant que ses présentations attendent encore, et pourra alors détruire le swapchain. Le jeton de présentation (R5, point 6) est donc un **prérequis de R6**, pas un correctif d'aujourd'hui.
- **Conséquence pour R10 et O17.** Le blocage documenté de `nextDrawable` n'est pas reproduit dans ces conditions : Core Animation fournit un drawable de plus. Il n'a été observé qu'une fois : 1 018 à 1 023 ms, délai par défaut, sur une couche réutilisée après une fin forcée (`r7-presentation/`, première exécution). R10 reste une défense ; O17 doit d'abord reproduire ce blocage (§5).
- **O17, étape 1 faite : blocage reproduit au niveau Metal** (sonde v11, `0d216bcb`, `build/astra/r13-o17-probe/`, M4 Pro, macOS 27.2, deux passes simples et une sous validation Metal).
  - **Ce qui ne fait pas attendre `nextDrawable`** : des drawables retenus au-delà de `maximumDrawableCount` (8 fournis sur 8 avec un maximum de 3, en 64×64 comme en 4K) ; des présentations demandées de 0,1 à 4 s à l'avance (`presentAtTime:`, comme MoltenVK avec `VK_GOOGLE_display_timing`), que Core Animation abandonne aussitôt, heure de présentation nulle ; une boucle serrée de 120 images (attente médiane 8 à 17 ms, au plus 35 ms : le rythme de l'écran) ; une couche réutilisée après une fin forcée, drawables relâchés à mesure.
  - **La recette** : sur une même couche, des présentations en attente derrière du travail bloqué, la taille du drawable changée (la fin forcée de MoltenVK), le travail libéré ; puis 3 drawables retenus. Le 4ᵉ `nextDrawable` attend environ 1 s, puis rend un **nouveau** drawable.

| Variante | Couche détachée | Fenêtre visible |
| --- | --- | --- |
| fin forcée, puis 3 drawables retenus | 9/9, 1 015 à 1 027 ms | 5/9, 1 004 à 1 011 ms ; les autres en 0 à 1 ms |
| la même, `allowsNextDrawableTimeout = NO` | 9/9, 1 016 à 1 026 ms | 6/9, 1 002 à 1 008 ms |
| témoin : taille 1×1 seule, sans fin forcée | 0/9 (3 à 12 ms) | 0/9 (7 à 11 ms) |
| fin forcée, puis taille rétablie | 9/9, 1 016 à 1 028 ms | 7/9, 1 002 à 1 011 ms |

  - **Une seule attente par couche** (sonde v12, `41adef90`, 12/12 sur couche détachée, dont 6 sous validation). Les drawables abandonnés restent retenus, comme MoltenVK le fait, et la taille est rétablie comme par un swapchain de remplacement. Six demandes, chacune retenue : seule la **4ᵉ** attend (1 017 à 1 028 ms), avec ou sans délai d'expiration ; les suivantes prennent 6 à 11 ms. Une demande faite après avoir relâché les drawables abandonnés prend 7 à 27 ms.
  - **Ce que cela change.** L'attente existe, mais elle est bornée à environ 1 s, même sans délai d'expiration. Elle rend un drawable, pas `nil` : `getCAMetalDrawable()` réussit donc au premier essai, sans réessayer. Elle ne se produit qu'une fois par couche. Sur macOS 27.2, un encodage peut donc attendre environ 1 s dans `nextDrawable`, pas davantage, et la perte rapportée plus tard d'autant reste rapportée en temps fini. R10 y réduit une latence ; il ne corrige pas un blocage.
  - **Condition d'entrée en usage valide.** La fin forcée ne supprime les présentations que si elles sont encore derrière du travail non terminé au moment où la taille change. Hors perte, cela suppose de recréer le swapchain (`oldSwapchain`) ou de le détruire pendant ce travail. Recréer est légal ; détruire ne l'est qu'avec R6.
- Les versions successives de la sonde sont gardées : v1 (le mode fenêtre plante à la sortie, par libération en double de la fenêtre, et sa sortie est perdue), v2 (corrige ce point), v3 (témoin sans changement de taille), v4 (présentations en attente), v5 (réutilisation des textures), v6 (usage valide : travail terminé, puis fin forcée).

### 3.14 Sites qui commitent un command buffer Metal

Tous les commits passent par `MVKDevice::commitMTLCommandBuffer()` (contrôle `run-pervertex-handler-tracking-tests.sh`). Ses 7 appelants :

| Site | Encadré par `beginEncoding()` / `endEncoding()` | Ce que le command buffer encode | Pages hôte importées |
| --- | --- | --- | --- |
| `MVKQueueCommandBufferSubmission::commitActiveMTLCommandBuffer()` (`MVKQueue.mm:690`) | oui (`MVKQueue::submit`, `MVKQueue.mm:82`, `127`) | le travail de l'application | oui |
| `MVKQueuePresentSurfaceSubmission` (`MVKQueue.mm:938`) | oui (même chemin) | attentes, présentation | non |
| `MVKDevice::invalidateMappedMemoryRanges()` (`MVKDevice.mm:5101`) | **non** | `synchronizeResource:` du `MTLBuffer` de la mémoire, managé, sur macOS sans mémoire unifiée (`MVKDeviceMemory.mm:109-111`) | **oui** : ce buffer peut être celui d'une mémoire importée (`newBufferWithBytesNoCopy`), et la synchronisation écrit ses pages |
| `MVKImage::copyImageToMemory()` (`MVKImage.mm:822`) | **non** | `synchronizeTexture:` des textures de l'image, managées, même condition | **oui** : une image liée à une mémoire importée |
| `MVKQueue::waitIdle()` (`MVKQueue.mm:205`) | non | rien | non |
| `MVKPresentableSwapchainImage::acquireAndSignalWhenAvailable()` (`MVKImage.mm:1620`) | non | le signal d'un sémaphore (`encodeSignalEvent`) | non |
| `MVKDevice::releaseSemaphoreWaitsAfterLoss()` (`MVKDevice.mm:4076`) | non (appelé par `markLost()` et par la publication) | des signaux d'événements, sur la file de secours | non |

## 4. Conception révisée

### R1. Destruction différée, avant toute libération

1. `MVKVulkanAPIDeviceObject::destroy()` devient `final` :
   - si le device est en perte (`isLosing()`) **et n'est pas en cours de retrait**, l'objet est ajouté à une liste FIFO du device, et `destroy()` rend la main sans rien libérer ;
   - sinon, il appelle `destroyNow()`. C'est aussi le cas quand l'objet n'a plus de device : `MVKSwapchainImage::detachSwapchain()` met `_device` à nul (`MVKImage.mm:1545`).
2. `virtual void destroyNow()` fait par défaut `MVKVulkanAPIObject::destroy()`, c'est-à-dire la libération de la référence.
   - Les 7 surcharges du §3.1 deviennent des surcharges de `destroyNow()`.
   - **Leur appel à la base change aussi** : `MVKResource::destroy()`, `MVKVulkanAPIDeviceObject::destroy()`, `MVKImage::destroy()` et `MVKSwapchainImage::destroy()` deviennent `MVKResource::destroyNow()`, `MVKVulkanAPIDeviceObject::destroyNow()`, `MVKImage::destroyNow()` et `MVKSwapchainImage::destroyNow()`. Un appel resté à `destroy()` rentrerait dans le `destroy()` `final`, puis de nouveau dans `destroyNow()` : récursion sans fin.
   - `final` fait refuser par le compilateur toute nouvelle surcharge de `destroy()` : une sous-classe future ne peut plus contourner le report.
   - **Garde de réentrée.** Le `destroy()` `final` marque l'objet ; un second appel sur un objet déjà marqué est une erreur de programmation : assertion en Debug, retour sans effet en Release.
   - **Contrôle statique** (CPU, dans l'esprit de `run-pervertex-handler-tracking-tests.sh`) : aucun corps de `destroyNow()` n'appelle `::destroy()` ; aucune classe dérivée de `MVKVulkanAPIDeviceObject` ne déclare `destroy()`.
3. Le retrait du device (R5) vide la liste **dans l'ordre FIFO**, avant de démonter quoi que ce soit : il appelle `destroyNow()` sur chaque objet. L'ordre de destruction de l'application est ainsi rejoué (un buffer avant sa mémoire, par exemple).
   - Il vide la liste **jusqu'à ce qu'elle soit vide**, sans en prendre d'instantané.
   - Pendant le retrait, `destroy()` ne diffère plus rien (point 1). Les objets que détruisent les `destroyNow()` vidés, ou `~MVKDevice` lui-même, sont donc détruits aussitôt : les images de transfert de `MVKCommandEncodingPool::destroyMetalResources()`, les images présentables d'un swapchain différé.
4. Les destructions internes au device, avant son retrait, passent aussi par `destroy()` : images de transfert du pool d'encodage, images présentables. Pendant une perte, elles sont donc reportées aussi.
5. **Le swapchain retient sa surface**, de sa création à son destructeur. Il en va de même pour tout objet différé qui garde un objet de l'instance.

Destruction en course avec le début de la perte : un objet détruit juste avant, alors que du travail en attente l'utilise, reste un usage invalide de l'application. Ce cas est inchangé.

### R2. Acquisition Metal déléguée, par file Metal

0. **L'acquisition appartient à la file Metal, pas à `MVKQueue`.** Le fil d'acquisition et la réserve vivent dans l'entrée du cache de `MVKQueueFamily`, à côté de la `MTLCommandQueue`. `MVKQueue` retient sa file et une référence à cette entrée.
   - **File contaminée.** Quand la perte d'un device commence alors que du travail de MoltenVK est en cours sur une file Metal, cette file sort du cache : le prochain device qui demande cet index reçoit une file neuve. Le device perdu garde l'ancienne jusqu'à son retrait. Coût : une création de file Metal après une perte seulement.
   - **Devices vivants en même temps.** Un device sain qui partage déjà la file d'un device perdu attend le travail bloqué de l'autre, par les places **et** par l'ordre d'exécution de la file (§3.6). Ce n'est pas nouveau : `shared-queue-block` (§5.1) le reproduit sur le runtime actuel. R2 empêche qu'un encodage attende dans Metal, pas que le travail d'un device attende celui d'un autre dans l'ordre de la file ; seule une file par device vivant le réglerait. C'est une **question pour la revue** (§7), avec une recommandation plus bas.
1. **Aucun fil d'encodage ni de l'application n'appelle plus `commandBufferWithDescriptor:`.** Chaque file Metal a son fil d'acquisition de command buffers (file de dispatch série de l'entrée du cache, **qui ne sert qu'à cela** : les drawables ont les leurs, R10) et une petite réserve de command buffers **pré-acquis, jamais mis en file**, par sorte de descripteur (références retenues ou non, options d'erreur).
   - Prendre un command buffer, c'est le retirer de la réserve : aucun appel à Metal. Le fil d'acquisition la remplit en tâche de fond ; lui seul peut bloquer dans Metal.
   - Réserve vide (file saturée) : l'appelant attend par tranches de 1 ms. Si la perte commence, il rend `nil` **sans avoir appelé Metal**. Un encodage n'attend donc jamais Metal au-delà d'une tranche après le début de la perte.
   - Un command buffer obtenu trop tard par le fil d'acquisition, ou resté en réserve au retrait du device, est relâché sans `enqueue` ni `commit`. La sonde `abandon-probe` a montré, sur M4 et sur iPhone 18 Pro, qu'il rend alors sa place et n'exécute rien. Sa liste de handlers MoltenVK passe par `abandonMTLCommandBuffer()`, qui l'exécute une seule fois (`7758838b`).
   - Le libellé du command buffer est posé au moment où on le prend.
2. La `MTLCommandQueue` est créée avec `maxActiveMetalCommandBuffersPerQueue` + taille de la réserve places. La configuration garde donc son sens actuel : le nombre de command buffers Metal en vol pour le travail de MoltenVK ; la réserve s'y ajoute. Il n'y a plus de crédit MoltenVK à accorder avec Metal : la seule attente dans Metal est celle du fil d'acquisition, qui ne retient ni encodage ni device.
3. Le préremplissage (`vkBeginCommandBuffer`) passe aussi par la réserve : pendant une perte, le command buffer s'enregistre sans préremplissage. Il faut une garde pour l'encodeur immédiat, qui ne doit pas commencer sur `nil`.
4. Les autres appelants traitent `nil` comme en révision 3 : chemin nil de la soumission (perte), `waitIdle()` (R3), acquisition d'image et présentation déjà refusées pendant une perte.
5. **Vie.** Une requête d'acquisition en cours tient une référence au compte de vie du device (R5) tant qu'elle peut encore rendre un command buffer à l'appelant ; le fil d'acquisition lui-même ne tient que l'entrée du cache, qui survit au device.
6. **Coût.** Retrait lock-free de la réserve et un `dispatch_async` de remplissage par command buffer. À mesurer (O8) : c'est le seul coût nouveau sur le chemin de chaque soumission.

**Graphe des attentes.** Il ne doit contenir aucun cycle, avec ou sans perte :

| Qui attend | Quoi | Dont la fin dépend de |
| --- | --- | --- |
| fil d'acquisition de command buffers (un par file Metal) | une place de la file Metal | la fin de travail **déjà commité** sur cette file |
| fil d'acquisition de drawables (un par `CAMetalLayer`, R10) | un drawable libre | la fin de présentations de travail **déjà commité**, et l'affichage |
| encodage | la réserve, ou un drawable, par tranches de 1 ms ; sort sur perte | l'un des deux fils ci-dessus |
| publication de la perte | la fin des encodages | bornée : les encodages sortent sur perte |

- Aucun fil d'acquisition n'attend un encodage, ni un autre fil d'acquisition.
- Ces arêtes sont celles des appels directs d'aujourd'hui. Seul le fil commun de la révision 4 en ajoutait une, entre une attente de drawable et les acquisitions de command buffers mises en file derrière elle.

**Écarté : « garer » l'encodage** pendant l'appel à Metal, en le retirant de `_activeEncodings`. Au réveil, le fil reprendrait l'encodage de command buffers que l'application peut avoir libérés après le rapport de la perte.

**Écarté : la marge de places de la révision 3.** Elle supposait que Metal rend la place peu après le crédit, et que l'application ne prend pas les places libres de la file exportée ; ni l'une ni l'autre hypothèse n'est garantie (§3.12).

**Recommandation pour les devices vivants (point 0).** Une file Metal par device vivant : le cache ne rend une file qu'à un device qui ne la partage avec aucun autre device vivant, et une file que bloque le travail d'un device perdu ne revient au cache qu'une fois ce travail terminé. Coût : une création de file Metal par device vivant simultané (le cache garde son intérêt pour les suites de tests qui créent des devices l'un après l'autre). Décision à la revue (§7).

### R3. Toutes les attentes hôte sortent sur perte publiée

Règle unique pour chaque attente de l'inventaire §3.8 qui ne sort pas aujourd'hui : elle attend **par tranches de 1 ms**, et sort quand la perte est publiée. Elle rend alors `VK_ERROR_DEVICE_LOST`. Les attentes déjà inscrites au device (fences, sémaphores, événements) ne changent pas.

**Fait pour l'attente des résultats de requête** (`630b183e`), sous son oracle `query-wait-abandoned` (§0 octies). Le reste de R3 n'est pas codé ; son activation reste soumise à ses propres oracles.

- `MVKQueue::waitIdle()` : l'attente de `_execQueueJobCount` et celle du command buffer vide passent par tranches ; le command buffer vide signale un sémaphore depuis son handler, que le bloc retient, comme dans `continueOnNewMTLCommandBuffer()`. Pendant une perte, aucune acquisition (R2).
- `MVKQueryPool::getResults()` avec `VK_QUERY_RESULT_WAIT_BIT` : `wait_for` par tranches, avec la perte publiée dans le prédicat.
- `MVKSwapchain::waitForPresent()` : idem, dans la limite du délai de l'application.
- `invalidateMappedMemoryRanges()` et `copyImageToMemory()` : comme `waitIdle()`, leur attente de complétion venant après leur encadrement (R8).

Une tranche de 1 ms ne coûte que quand l'attente dure ; le chemin sans attente est inchangé.

### R4. Pools pendant la perte

| Pool | Pendant la perte |
| --- | --- |
| Descriptor sets (`vkFreeDescriptorSets`, `vkResetDescriptorPool`) | **Pool épuisé** (§3.10) : pendant une perte, `freeDescriptorSets()` ne rend rien aux listes libres, et `reset()` ne rembobine pas les allocateurs ; il marque le pool épuisé. Toute allocation suivante dans ce pool rend `VK_ERROR_OUT_OF_POOL_MEMORY`, ce que Vulkan permet. Tout est rendu à la destruction du pool, elle-même différée (R1). Le retour arrière interne d'une allocation qui échoue (`MVKDescriptorSet.mm:2217-2225`) ne touche que des régions que rien n'a encore utilisées : inchangé. |
| Command buffers et commandes (`vkResetCommandPool`, `vkResetCommandBuffer`, `vkFreeCommandBuffers`, reset implicite de `vkBeginCommandBuffer`) | Recyclage **conservé** : aucun handler ne les capture (§3.4). L'oracle O6 le prouve. |
| Allocations temporaires (`MVKMTLBufferAllocationPool`) | Inchangé : rendues exactement une fois, par leur handler (`7758838b`). Leur pool vit tant que le pool de commandes, dont la destruction est différée. |
| Requêtes (`vkResetQueryPool`) | Inchangé. Un `finishQueries` en retard peut encore marquer des requêtes disponibles. Après une perte, les résultats sont indéfinis selon Vulkan ; la mémoire reste valide, puisque la destruction du pool est différée. |
| Visibility buffers du device | Rendus au commit, comme en amont. **Non analysé** pour la perte : question ouverte. |

### R5. Vie du device : un seul compte, retrait exclusif et sans attente

1. **Un compte de vie fort/faible.** La vie du device est portée par un bloc de contrôle séparé (ancre), alloué avec le device et qui lui **survit**, comme le bloc de contrôle d'un `std::shared_ptr`. Il tient un compte **fort** et un compte **faible**. L'application tient une référence forte de la création à `vkDestroyDevice`. En tient aussi une, le temps de son existence :
   - **chaque handler Metal enregistré**, séparément : `commitMTLCommandBuffer()` enregistre jusqu'à deux handlers (« scheduled » et « completed »), qui peuvent s'exécuter sur des fils différents, en même temps. Chacun prend sa référence à l'enregistrement et la rend comme dernier geste, comme il décrémente déjà `_pendingMTLCommandBufferHandlers` ;
   - chaque encodage (`beginEncoding()` / `endEncoding()`) ;
   - chaque job de publication de la perte (prise dans `markLost()` avant le `dispatch_async`) ;
   - chaque requête d'acquisition qui peut encore rendre un command buffer ou un drawable (R2, R10).
   - Les compteurs `_activeEncodings` et `_pendingMTLCommandBufferHandlers` restent, pour la publication et les crochets de test ; ils ne décident plus de la vie du device.
2. **Transition exclusive.** Le fil dont le décrément du compte fort rend 1 est, par construction, **le seul** à retirer le device. Une **promotion** d'une référence faible en forte ne réussit que si le compte fort n'est pas nul, par un échange atomique (comme `std::weak_ptr::lock()`) : une fois le retrait commencé, plus aucune promotion ne réussit, et aucune promotion réussie ne peut précéder un retrait qui ne l'attendrait pas. `vkDestroyDevice` rend la référence forte de l'application :
   - s'il est ce fil, il retire le device sur place, comme aujourd'hui pour une application normale ;
   - sinon, il rend la main.
   - Un autre fil qui rend la dernière référence (handler, fin d'encodage, job) met le retrait en file sur une **file série de MoltenVK** : jamais dans un handler Metal.
   - Aucune lecture séparée de plusieurs compteurs ne décide plus du retrait : deux chemins ne peuvent plus conclure tous deux « tout est à zéro ».
3. **Retrait**, par le seul fil qui le possède, **sans aucune attente** :
   - passer en état de retrait (R1, point 1), puis vider la liste différée jusqu'au bout ;
   - **terminer les présentations en attente** (point 6) ;
   - puis `~MVKDevice`, sans ses attentes actuelles, tenues par construction. Son `dispatch_sync(_lossPublisher)` (`MVKDevice.mm:5855`) rend alors la main aussitôt, puisque le job de publication tient une référence (point 1).
   - **La file de retrait n'attend jamais.** Ce qui dépendrait d'un événement futur ne bloque pas un retrait : c'est la dernière référence rendue qui déclenche le retrait. Un device bloqué ne peut donc pas retarder le retrait des autres devices.
4. Le device retient son instance. `vkDestroyInstance` après `vkDestroyDevice` diffère donc la suppression de l'instance jusqu'à celle du device, sur la même file.
5. Plus d'hypothèse sur les handlers de présentation : la sonde de §3.13 montre qu'après une fin forcée, ils ne sont pas appelés.
6. **Jeton de présentation détachable** (motif de R9) :
   - `addPresentedHandler()` crée un jeton compté qui **possède** ce que `endPresentation()` utilise : l'image (sa référence de `beginPresentation()`), le signaler (sémaphore et fence retenus par `track()`), les informations de présentation.
   - Le bloc du handler ne capture que ce jeton, et le jeton ne tient qu'une **référence faible** vers l'ancre du device (point 1) : jamais une référence forte, qui ferait attendre au retrait un callback qui ne vient pas (§3.13).
   - **Entrée du callback, arbitrée avec le retrait** :
     1. le callback tente de promouvoir sa référence faible ;
     2. **échec** : le retrait a commencé, et c'est lui qui termine la présentation (ci-dessous). Le callback ne touche que le jeton et rend la main ;
     3. **réussite** : le retrait ne peut plus commencer avant que le callback rende sa référence forte. Le callback fait passer le jeton de « attaché » à « terminé » sous son verrou ; s'il gagne, il exécute `endPresentation()`, device vivant. Il rend sa référence forte en **dernier geste**, après ses `release()`. Si c'était la dernière, le retrait est mis en file sur la file de retrait, jamais exécuté dans le callback.
   - **Retrait** : une fois le compte fort à zéro, il vide la liste différée ; pour chaque jeton encore attaché que tient un swapchain, il le fait passer à « terminé » et exécute lui-même `endPresentation()`. Aucun callback ne peut alors l'exécuter en même temps, puisqu'aucune promotion ne réussit plus.
   - Le retrait n'attend toujours rien : un callback promu retarde le **départ** du retrait, pas son déroulement.
   - **Une présentation qui commence après le détachement de son image** (handler « scheduled » exécuté après la destruction du swapchain, le plantage mesuré en §3.13) se termine aussitôt : elle signale et rend son signaler, sans `beginPresentation()` ni référence à un swapchain disparu.
   - Hors perte, sans destruction de swapchain, le handler fait le travail comme aujourd'hui. Avec destruction de swapchain, `MVKSwapchain::destroyNow()` termine les jetons restants : callbacks supprimés par la fin forcée, image et signalers rendus.

### R6. Publication en temps fini

`publishLoss()` n'attend plus que `_activeEncodings`, borné grâce à R2. Il n'attend plus les handlers, **pour tous les devices**, y compris ceux qui importent de la mémoire hôte (R8). Les attentes hôte de §3.8 rendent `VK_ERROR_DEVICE_LOST` en temps fini (R3).

La publication ordonnée de `c78c0289` est inchangée. Une soumission bloquée retient les soumissions suivantes de sa file jusqu'à sa fin, ou jusqu'au retrait du device. Leurs fences et sémaphores ne sont pas signalés, ce qui est correct pendant une perte.

### R8. Mémoire hôte importée : `vkFreeMemory` attend le retrait du travail

**Implémenté** (`67dd59d4`, complété en `1deebd18` : acquisition avant l'encadrement, garde d'admission, attente limitée aux mémoires importées avant la perte), oracles aux §0 sexies et §0 septies. L'attente de complétion de l'invalidation et de la copie image vers mémoire peut encore ne pas finir ; c'est le cas de R3, non codé.

- **Choix de la conception : l'option (b).** La perte est publiée en temps fini pour tous les devices (R6). Ce qui attend, c'est `vkFreeMemory` d'une allocation `VK_EXT_external_memory_host` qui existait au début de la perte.
- **Inventaire fermé à la publication, pas à `markLost()`.** Un encodage commencé avant `markLost()` peut encore commiter ses command buffers Metal après : `execute()` ne teste la perte qu'au début, et le commit précède `endEncoding()`. Un inventaire relevé à `markLost()` le manquerait (constat de la revue).
  - Chaque handler Metal enregistré avant la fermeture incrémente un compteur `_handlersBeforeInventory`, et le décrémente à la fin de son exécution. Il garde pour cela un indicateur capturé à l'enregistrement.
  - `publishLoss()` ferme l'inventaire **après** que `_activeEncodings` est revenu à zéro. Il n'y a plus alors d'encodage, donc plus de commit de travail d'application : les enregistrements se font dans un encodage, qui précède `endEncoding()`, qui précède la lecture de zéro par la publication. Seul le command buffer de secours de la publication est enregistré ensuite ; il ne touche pas la mémoire de l'application.
- `vkFreeMemory` d'une allocation importée attend, **par tranches de 1 ms et sans tenir aucun verrou de MoltenVK**, que l'inventaire soit fermé, puis que `_handlersBeforeInventory` revienne à zéro. Il libère alors l'allocation comme aujourd'hui. Un avertissement est émis à la première tranche.
- **Périmètre de l'inventaire : tous les sites qui peuvent écrire dans des pages importées** (§3.14).
  - `invalidateMappedMemoryRanges()` et `copyImageToMemory()` **acquièrent** leur command buffer, puis sont **encadrés comme des encodages** jusqu'au commit inclus : `beginEncoding()` après l'acquisition, puis une **garde d'admission** (`isLosing()`), puis le commit, puis `endEncoding()`. L'acquisition, qui bloque quand la file Metal est pleine, et l'attente de complétion, par tranches (R3), sont hors de l'encadrement : la publication, qui attend les encodages, n'attend ni l'une ni l'autre, et il n'y a pas de cycle.
  - Un encadrement admis avant la perte est attendu par la publication, donc son commit précède la fermeture et il est compté. Un encadrement commencé pendant la perte est refusé par la garde : son command buffer est abandonné sans commit, et rien n'est synchronisé.
  - `waitIdle()`, l'acquisition d'image et le command buffer de secours n'encodent aucun accès à une mémoire : ils restent hors encadrement. Le contrôle statique O20 le vérifie et refuse tout nouveau site non classé.
- Une allocation importée **après** le début de la perte ne l'attend pas : aucun travail admis avant la perte ne l'utilise. Une allocation dont l'import a échoué non plus : `vkAllocateMemory` la libère par le même chemin (`isHostMemoryImportedBeforeLoss()`, `1deebd18`).
- **Le blocage est déplacé, pas supprimé.**
  - `vkFreeMemory` n'attend sans borne que si l'application bloque elle-même son propre travail Metal pour toujours.
  - Une application mono-fil qui libère sa mémoire **avant** de libérer son travail s'y bloque. Elle se bloque aujourd'hui de la même façon dans l'attente hôte : (b) n'est pas pire.
  - (b) respecte la liste des attentes que la spécification oblige à rendre la main en temps fini, qui ne contient pas `vkFreeMemory`.
- **Variante (a), non retenue** : garder, pour ces devices, la publication actuelle. G1 est alors abandonné pour les applications qui importent de la mémoire hôte ; les attentes hôte peuvent ne pas rendre la main.
- (c) Refuser l'import de mémoire hôte sur un device qui exporte ses files Metal : trop restrictif, écarté.
- La revue peut encore préférer (a) ; R6, R7 et O11 seraient alors à réécrire ensemble.

### R9. Listeners timeline : un jeton détachable

- `registerWait()` crée, pour chaque inscription, un petit jeton compté : un verrou et un pointeur vers le `MVKFenceSitter`.
- Le bloc du listener ne capture que ce jeton. Il ne retient plus le sémaphore : sa fin ne peut plus déclencher une destruction qui touche le device.
- `unregisterWait()` détache le jeton, sous son verrou, avant le retour de l'attente. Le bloc ne signale que si le jeton est encore attaché.
- Effets :
  - l'ABA de §3.9 disparaît : l'identité est celle du jeton, plus l'adresse d'un objet de pile ;
  - un listener qui ne rappelle jamais ne retient qu'un jeton, pas le sémaphore ni le device : il n'entre pas dans R5.
- Cette pièce corrige aussi un défaut actuel, sans lien avec la perte.
- **Implémenté seul, avec l'accord de la revue** : `d24159ce` sur `claude/pervertex-generic`, `90cef75a` sur `claude/device-loss-generic`. `vkWaitSemaphores()` ne relit **pas** la valeur au réveil : une relecture ferait passer `timeline-listener-aba` sans prouver le jeton. Elle reste une défense possible, en plus.

### R10. Drawables acquis hors de l'encodage

**Implémenté** (`a3f02d1c`) sous O17, sur le fondement du verdict de la revue sur la question 4 (§0 nonies). Écart avec le texte ci-dessous : la file est portée par la surface, qui possède la couche, et non par un fil d'acquisition distinct.

- `getCAMetalDrawable()` ne rappelle plus `nextDrawable` sur le fil d'encodage. Il le demande au **fil d'acquisition de drawables de la couche** du swapchain (un par `CAMetalLayer`, distinct des fils de command buffers de R2), et attend par tranches de 1 ms.
- Si la perte commence, l'encodage sort sans drawable : la soumission est perdue, comme sur le chemin nil.
- Un drawable obtenu après la sortie de l'encodage est relâché sans présentation ; il revient à la couche.
- Hors perte, rien ne change pour l'application : le délai de `nextDrawable` et le nombre d'essais sont ceux d'aujourd'hui.

### R7. Hors garantie, à dire explicitement

- Détruire un objet, ou le device, **avant** le début d'une perte, alors que du travail en attente l'utilise : usage invalide, inchangé.
- Une application qui sature elle-même une file exportée : le fil d'acquisition de cette file attend dans Metal ; aucun encodage ni la publication ne l'attendent (R2).
- Un travail que l'application ne libère jamais : le device, et les objets différés, restent alloués jusqu'à la fin du processus. `vkDestroyDevice` rend la main. La fuite se limite au device perdu : aucun accès à de la mémoire libérée.
- Mémoire hôte importée au début de la perte : `vkFreeMemory` de cette allocation peut attendre aussi longtemps que le travail que l'application bloque elle-même (R8).
- Un device sain qui partage, au moment de la perte d'un autre, la file Metal que bloque le travail de celui-ci (R2, point 0).
- Un handler de présentation que Metal ne rappelle jamais : il ne retient plus rien du device (R5, point 6), et la fin de présentation est faite par le retrait ; seul son jeton reste alloué.

## 5. Oracles, à écrire avant l'implémentation

Chaque oracle doit échouer sur `7758838b` (ou avec la pièce correspondante retirée) et passer après. **Aucun oracle ne peut être déclaré « non couvert » : R6 n'est pas activable tant que tous, dont O15 et O17, ne sont pas verts sur la même bibliothèque.** **Toute attente hôte d'un oracle démarre avant la perte**, sur un fil, et reçoit 2 s à compter de la perte ; une attente qui rend la main avant la perte fait échouer l'oracle. Sur `7758838b`, O2 à O6 échouent d'abord par **délai dépassé** : la perte n'est pas rapportée en 2 s, et l'étape suivante n'est jamais atteinte. Leurs témoins de fond sont donc ceux de O7, pièce par pièce, sur la bibliothèque corrigée. Par exemple, pour O2, la référence faible devient nulle aussitôt après `vkDestroyBuffer` si R1 intercepte au point central, après les surcharges. Tous tournent sous validation Metal de l'API et des shaders, avec des handlers retardés comme les oracles actuels.

| Oracle | Scénario | Réussite |
| --- | --- | --- |
| **O1** `external-queue-wait` | le reproducteur actuel, plus une variante dont l'attente de fence démarre avant la perte | perte rapportée en moins de 2 s ; C s'exécute après le signal de l'application, sans erreur de validation |
| **O2** destruction après le rapport | après le rapport, et pendant que C est bloqué, détruire tout ce que C utilise : `VkBuffer` (surcharge `destroyNow`), vue de buffer, vue d'image, sampler, mémoire, pipeline, pool de commandes, descriptor pool. Libérer ensuite l'événement, puis détruire le device | aucune erreur de validation, aucun plantage. **Conservation vérifiée par trois preuves indépendantes** : (1) le test ne retient pas le `MTLBuffer` exporté (`VK_EXT_metal_objects`) de la cible de C, il n'en garde qu'une référence faible (`objc_storeWeak`) : non nulle après les destructions, nulle après le retrait du device ; (2) la valeur écrite par C après le signal se lit par cette référence ; (3) le crochet `mvkTestGetDeferredDestroyCount` compte exactement les objets détruits pendant la perte, puis zéro après le retrait. Un objet de chacune des 7 classes à surcharge est détruit (O13) |
| **O3** device et instance détruits pendant le blocage | `vkDestroyDevice` puis `vkDestroyInstance` juste après le rapport | les deux rendent la main en moins de 100 ms ; après le signal, le device est supprimé une seule fois, hors d'un fil Metal, puis l'instance (crochet de test) |
| **O14** retrait exclusif | 200 itérations : `vkDestroyDevice` en course avec le dernier handler, retardé de 0 à 2 ms selon l'itération | crochet `mvkTestGetDeviceReapCount` : exactement un retrait par device ; aucun plantage |
| **O15** présentation et retrait | swapchain `VK_EXT_metal_surface` sur une `CAMetalLayer` détachée (la sonde §3.13 montre qu'elle fournit des drawables et rappelle les handlers), puis dans une fenêtre ; présentations en attente derrière du travail bloqué, perte, `vkDestroySwapchainKHR` et `vkDestroyDevice` pendant le blocage, puis signal | le retrait se termine sans attendre ; crochet de test : chaque jeton de présentation terminé **exactement une fois** (par le retrait) ; image et signalers rendus. **Témoin** : le même scénario sans destruction du swapchain, où le handler est appelé après le signal : le jeton est terminé une fois, par le handler, et aucun sémaphore n'est signalé deux fois. Autre témoin : la file de retrait traite le retrait d'un second device pendant que le premier a des présentations sans callback. **Les deux ordres de R5 (point 6) sont forcés**, sous Guard Malloc : (A) *callback entré* — un swizzle de `-[MTLSharedEvent setSignaledValue:]` sur l'événement importé du sémaphore d'acquisition bloque 300 ms le callback **dans** `endPresentation()`, pendant que l'application rend sa dernière référence ; le retrait ne commence qu'après le retour du callback (horodatages par crochet) ; (B) *retrait d'abord* — un swizzle de `-[CAMetalDrawable addPresentedHandler:]` retarde de 300 ms l'appel du bloc de MoltenVK ; le device est retiré avant, la promotion échoue, le callback ne fait rien, et le retrait a terminé le jeton une fois |
| **O16** réserve d'acquisition | file Metal saturée par l'application sur la file exportée (4 places) ; une soumission qui attend la réserve ; perte | rapport en moins de 2 s ; aucun fil d'encodage dans Metal (échantillonnage des piles) ; le command buffer obtenu plus tard est relâché sans exécution |
| **O17** drawable | **Critère d'ordre (révision 12), écrit : `drawable-wait-loss`** (§0 nonies). `nextDrawable` entré avant la perte et pas revenu ; avant R10, un encodage y attend ; après R10, aucun, la perte est publiée avant son retour, et le drawable tardif est rendu. **6/6 rouges sur `630b183e`, 6/6 verts sur `a3f02d1c`** (macOS 27.2, couche détachée). Étape 1 au niveau Metal : §3.13. Anciennes descriptions : le seuil de 2 s ne pouvait pas être rouge sur macOS 27.2 (question 4). Plus ancienne : puis la même condition sous une couche d'application avec `allowsNextDrawableTimeout = NO`, une soumission qui rend dans une image de swapchain, et une perte | rapport en moins de 2 s ; aucun fil d'encodage dans `nextDrawable` (échantillonnage des piles) ; un drawable obtenu plus tard est rendu à la couche |
| **O18** handlers séparés | un command buffer avec handlers « scheduled » et « completed ». **Les deux ordres sont forcés** par les crochets existants : « completed » terminé pendant que « scheduled » dort encore 200 ms, puis l'inverse ; perte, `vkDestroyDevice` pendant le handler retardé | le device n'est retiré qu'après le retour des deux handlers, dans les deux ordres (crochet de test) ; aucun accès après retrait sous Guard Malloc |
| **O20** sites de commit | contrôle statique, CPU, dans l'esprit de `run-pervertex-handler-tracking-tests.sh` : chaque appel de `commitMTLCommandBuffer()` figure dans une liste classée (encadré, ou sans accès mémoire) ; pour les sites « sans accès mémoire », aucun encodeur de blit, de calcul ou de rendu entre l'acquisition et le commit | tout site non classé, ou un site sans accès mémoire qui gagne un encodeur, fait échouer le contrôle. **Écrit** : `run-pervertex-commit-sites-check.sh` (`3124ab84`), renforcé (`55b0f996`, `86ea6506`, `ab4e1af7`, `e53de67b`) : fonctions libres ; dans les sites encadrés, acquisition avant le début, garde `isLosing()` entre le début et le commit, puis commit, puis fin, aucune attente de complétion avant la fin ; `pullFromDevice()` n'acquiert pas ; handler de fin décompté sans autre condition que l'inventaire ouvert et après les autres handlers de fin ; aucun commit Metal direct. Rouge sur le runtime de `f97faeb7` (3 problèmes) et sur celui de `67dd59d4`, première version de R8 (3 problèmes, contrôlés au commit `df663204`, même runtime), vert sur le runtime final `d4110762` (7 sites) ; 10 témoins négatifs rouges (§0 sexies, §0 septies) |
| **O19** progression | 200 itérations d'entrelacements variés, avec une graine affichée : moment de la perte (avant, pendant ou après l'encodage de C), retards et ordre des handlers, attente hôte démarrée avant ou après la perte, destruction du device avant ou après le signal de l'application | chaque attente hôte rend la main en moins de 2 s ; chaque device est retiré exactement une fois ; le compte de vie revient à zéro (crochet) ; aucune erreur de validation |
| **O4** file saturée | `maxActiveMetalCommandBuffersPerQueue=4` ; l'application garde 2 command buffers en attente sur la file exportée ; MoltenVK remplit les places restantes ; perte | rapport en temps fini ; `vkBeginCommandBuffer` avec préremplissage, appelé pendant la perte, rend la main |
| **O5** attentes idle | `vkQueueWaitIdle` et `vkDeviceWaitIdle` après la perte, pendant que C est bloqué | `VK_ERROR_DEVICE_LOST` en moins de 2 s |
| **O6** pools pendant la perte | après le rapport : `vkFreeDescriptorSets` puis `vkResetDescriptorPool` sur le pool des descriptor sets de C, puis une allocation ; reset, libération, réallocation et réenregistrement des command buffers de C ; puis signal | pas d'erreur de validation ; l'allocation après le reset rend `VK_ERROR_OUT_OF_POOL_MEMORY` ; le crochet `mvkTestGetDescriptorPoolState` montre les allocateurs **non rembobinés** (même `_gpuBufferUsed` qu'avant le reset) ; la région d'argument buffer de C garde son contenu jusqu'au signal ; allocations temporaires rendues exactement une fois (`mvkTestGetOutstandingCommandPoolAllocations`) |
| **O9** attentes sans délai | `external-queue-wait-idle` et `external-queue-wait-query` (§5.1) ; `vkWaitForPresentKHR` si un chemin de présentation sans fenêtre est disponible | perte rapportée en moins de 2 s, puis C après le signal |
| **O10** files Metal | `shared-queue-block` (§5.1) ; puis un troisième device, créé après la perte du premier alors que son travail est bloqué | le troisième reçoit une autre file Metal, et sa soumission se termine ; `shared-queue-block` reste `BLOCKER` tant que la question du §7 n'est pas tranchée |
| **O11** mémoire hôte importée | **Écrit pour ce qui ne dépend pas de R6** : modes `free-imported-waits`, `-late-commit` et `-slow-handler` (§0 sexies), `free-imported-late-allocation` et `-failed-allocation` (§0 septies). Ils appellent `vkFreeMemory` après `markLost()` sans attente hôte préalable, puisque sans R6 cette attente ne rend pas la main (`external-queue-wait`). Deux variantes. (1) C écrit dans un buffer lié à de la mémoire importée. **L'entrelacement de la revue est forcé** : C est retenu 300 ms à la création de son premier encodeur Metal, donc avant que `commitMTLCommandBuffer()` décide de le compter, pour que ce commit ait lieu **après** `markLost()`, encodage de C en cours. L'attente hôte démarre avant la perte ; `vkFreeMemory` est appelé sur un autre fil dès le rapport ; l'application ne rend ses pages qu'après son retour | l'attente rend `VK_ERROR_DEVICE_LOST` en moins de 2 s ; `vkFreeMemory` ne rend la main qu'après le retrait de C (horodatages : fin du handler de C, puis retour de `vkFreeMemory`) ; la valeur écrite par C est dans les pages avant leur libération ; l'avertissement est émis. **Témoin négatif** : inventaire relevé à `markLost()` — `vkFreeMemory` rend la main avant le retrait de C. (2) Sur un Mac sans mémoire unifiée, s'il en est un disponible : `vkInvalidateMappedMemoryRanges` sur la mémoire importée, en cours à `markLost()` ; même critère ; témoin négatif sans l'encadrement. Sans Mac sans mémoire unifiée, la variante (2) n'est pas exécutable et le dit : O20 reste alors la seule preuve pour ces deux chemins |
| **O12** listeners | `timeline-listener-aba` (§5.1), chaque attente jugée sur 10 tours ; puis, après une perte, destruction du sémaphore et du device pendant qu'un listener sur un événement importé attend, et signal ensuite | aucun faux succès ; aucun plantage sous Guard Malloc. **Fait pour l'ABA** : 6/6 rouges avant R9 (18 à 19 attentes fausses sur 20), 6/6 verts après |
| **O13** récursion de `destroyNow()` | contrôle statique de R1 ; O2 détruit un objet de chacune des 7 classes, dont un swapchain et ses images si un chemin sans fenêtre existe | contrôle vert ; aucune récursion, aucun plantage |
| **O7** témoins négatifs | chaque pièce retirée à tour de rôle (R1 sans `final`, avec interception au point central, ou avec un appel à la base resté à `destroy()` ; R2 avec un appel direct à Metal sur le fil d'encodage ; R10 avec `nextDrawable` sur le fil d'encodage ; R5 avec deux lectures de compteurs au lieu du compte unique, avec une seule référence pour les deux handlers Metal, ou avec les handlers de présentation comptés dans la vie du device ; R8 sans l'attente de `vkFreeMemory`, ou avec l'inventaire relevé à `markLost()` ; R3 avec `waitUntilCompleted` ; R5 avec suppression inline ; R8 désactivé ; R9 avec l'adresse du sitter) | l'oracle correspondant échoue |
| **O8** non-régression et coût | oracles de perte, binaires, de continuation, suite M4, CTS de synchronisation ; `QueueRetirementBench` et `BinarySemaphoreBench` | tout vert ; coût mesuré avant/après, sur une charge identique |

### 5.1 Reproducteurs écrits dès maintenant

Ces modes de `PerVertexLossTests.mm` reproduisent, sur le runtime actuel, les constats vérifiables sans implémenter la conception. Résultats : section de la quatrième revue du rapport.

| Mode | Constat |
| --- | --- |
| `external-queue-wait-idle` | `vkQueueWaitIdle` ne rend pas la main derrière le travail bloqué |
| `external-queue-wait-query` | `vkGetQueryPoolResults` avec `VK_QUERY_RESULT_WAIT_BIT` non plus |
| `shared-queue-block` | deux devices reçoivent la même file Metal ; un device sain attend le travail d'un device perdu, par les places (file pleine) ou par l'ordre d'exécution (témoin à 64 places) |
| `timeline-listener-aba` | sans perte : un ancien listener réveille une attente plus récente, qui rend `VK_SUCCESS` sous sa valeur. **Corrigé par R9** (`d24159ce`) |

### 5.2 Jeton de présentation : prémisse vérifiée avant implémentation

La revue autorisait le jeton comme correctif isolé, avec un oracle qui met le callback en concurrence avec la destruction du swapchain. Avant de toucher au runtime, j'ai vérifié qu'un défaut existe aujourd'hui en usage valide. Il n'en existe pas (§3.13) :

| Oracle (`PerVertexLossTests.mm`, `d5ba4e27`) | Usage | `lib-d24159ce` |
| --- | --- | --- |
| `present-scheduled-after-destroy` : destruction après `vkQueueWaitIdle`, handlers retardés de 300 ms | valide | 4/4 verts |
| `present-destroy-race` : 20 tours, handlers retardés de 0 à 3 ms, en course avec la destruction | valide | 4/4 verts |
| `present-pending-destroy` : destruction pendant que les présentations attendent du travail bloqué | invalide hors perte ; légal après R6 | 4/4 plantages dans `MVKSwapchain::beginPresentation()` |

- Un correctif isolé n'aurait eu, comme oracle rouge, qu'un scénario que Vulkan interdit aujourd'hui. Je ne l'ai donc **pas implémenté**.
- Le jeton reste une pièce de R5, livrée avec R6.
- Ses oracles sont prêts : `present-pending-destroy` passera du plantage au vert avec R5, puis sa variante avec perte (O15) avec R6. Les deux modes valides restent des oracles de non-régression.
- Le crochet `mvkTestGetUnpresentedImageCount` (`d5ba4e27`) n'existe que dans les bibliothèques construites à partir de ce commit : `begun_at_destroy=-1` sur `lib-d24159ce` est attendu.

## 6. Ordre d'implémentation proposé, après la revue

0. R9 et O12 : fait (`d24159ce`).
1. R1, avec la surface retenue, puis O2 et O13.
2. R3, puis O5.
3. R2 et R10, puis O4, O10, O16 et O17.
4. R5, dont le jeton de présentation (§5.2), puis O3, O14, O15 et O18.
5. R8, avec l'encadrement de l'invalidation et de la copie image vers mémoire, puis O11 et O20 : fait (`67dd59d4`), sauf la variante (2) d'O11, faute de Mac sans mémoire unifiée.
6. R4, puis O6.
7. O7, O8 et O19.
8. R6 : O1 et O9 passent de `BLOCKER` à `PASS`, **seulement si O2 à O8 et O10 à O19 sont verts** sur la même bibliothèque.

## 7. Questions pour la revue

1. La réserve d'acquisition (R2) : quelle taille par sorte de descripteur ? Proposition : 2.
2. Le report limité aux objets du device, la surface étant retenue par le swapchain, suffit-il ?
3. La fuite d'un device dont le travail n'est jamais libéré est-elle acceptable, faute de mieux ?
4. La quarantaine des descriptor pools peut rendre `VK_ERROR_OUT_OF_POOL_MEMORY` pendant une perte. Est-ce acceptable ?
5. Faut-il analyser les visibility buffers du device (R4) avant l'implémentation, ou pendant ?
6. **Files Metal partagées entre devices vivants** (R2, point 0) : faut-il que la famille cesse de donner une même file à deux devices vivants, au prix d'une création de file par device ? Le reproducteur montre que le partage lie aussi l'ordre d'exécution des deux devices, perte ou non. Ou bien un device sain peut-il rester bloqué tant que le travail d'un autre device, perdu, ne se termine pas ? Recommandation : une file par device vivant (R2).
7. **Mémoire hôte importée** (R8) : (b) accordé par le GO limité ; fait (`67dd59d4`). Reste la variante (2) d'O11, sans matériel.
8. **Handlers de présentation** (R5) : l'hypothèse a été mesurée fausse (§3.13) ; le jeton détachable, sans attente, répond-il à la question ?
9. **R9** : accordé par la revue ; fait.
10. **Jeton de présentation** (R5, point 6) : la mesure de §5.2 montre qu'il ne corrige rien en usage valide aujourd'hui. D'accord pour qu'il reste une pièce de R5, livrée avec R6 plutôt que seule ?
