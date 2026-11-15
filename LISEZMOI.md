# Fouine

Recherche de fichiers pour macOS dans l'esprit d'EasyFind, avec un index : les noms se
trouvent instantanément sur tout le disque, fichiers cachés et système compris.

## Construire et lancer

```bash
./build.sh
```

```bash
open build/Fouine.app
```

Au premier lancement, accordez **Accès complet au disque** à Fouine (Réglages ›
Confidentialité et sécurité). L'indexation initiale démarre alors (environ 35 s pour 7 millions d'éléments).

## Fonctionnement

- **Index** : base SQLite dans `~/Library/Application Support/Fouine/index.sqlite`
  (nom, dossier, taille, date). Recherche de sous-chaînes par index trigramme (FTS5),
  insensible à la casse et aux accents. Mesuré sur 7,3 millions d'éléments : indexation
  complète en 35 s, base de 776 Mo.
- **Indexation** : parcours parallèle du disque (`getattrlistbulk`), une file de 8 fils par
  volume (au-delà, les lectures se gênent dans le noyau ; par volume, pour qu'un disque lent
  ne retienne pas les SSD), un seul fil écrit en base.
- **Rafraîchissement** (⌘R) : différentiel. Seuls les dossiers dont la date a changé sont
  relus, soit 7,6 s au lieu d'un index complet. Il ne voit pas la simple modification du
  contenu d'un fichier, que le suivi continu traite. « Reconstruire l'index complet » reste
  dans le menu Fouine.
- **Mise à jour de l'index** : FSEvents suit tout le disque en continu. Au lancement,
  les changements survenus pendant que l'app était fermée sont rejoués ; si l'historique
  système est perdu, l'index est reconstruit.
- **Critères** : fichiers / dossiers, opérateurs (tous les mots, un des mots, expression
  exacte, jokers, expression régulière), filtres de type, de date et de taille, contenu
  des paquets, éléments invisibles, dossiers regroupés en premier.
- **Contenus** : recherche à la demande (touche Retour). Les fichiers du périmètre sont
  lus en parallèle ; les fichiers cloud non téléchargés sont ignorés. La casse n'est
  ignorée que pour les lettres sans accent. Jokers et expressions régulières ne
  s'appliquent qu'aux noms.
- **Non indexés** : `/System/Volumes` (doublon du volume de données), `/dev`, les
  instantanés Time Machine et les volumes réseau.
- **Langue** : l'interface suit la langue de macOS (français, anglais). Les clés sont les
  textes français du code ; l'anglais est dans `Resources/en.lproj/Localizable.strings`.
- **Fenêtre** : taille et position sont mémorisées d'un lancement à l'autre.

## Mise à jour de l'application

L'app intègre Sparkle et lit `appcast.xml` dans la dernière GitHub Release de
`blckdvc/Fouine`. Tant que ce dépôt n'existe pas, la vérification échoue sans conséquence.

```bash
./release.sh 0.2.0
```

Ce script compile, archive, signe l'archive avec la clé Sparkle du trousseau, génère
`appcast.xml` et crée la Release. La clé privée ne quitte pas le trousseau : sans elle,
aucune mise à jour ne peut être publiée pour les copies déjà installées.

## Code

| Fichier | Rôle |
| --- | --- |
| `Database.swift` | Connexion SQLite et schéma |
| `IndexStore.swift` | Écritures dans l'index |
| `FastScanner.swift` | Parcours parallèle du disque |
| `IndexService.swift` | Indexation complète et application des événements |
| `Watcher.swift` | Flux FSEvents |
| `SearchEngine.swift` | Recherche par nom et par contenu |
| `SearchModel.swift`, `ContentView.swift` | Interface SwiftUI |
| `ResultsTable.swift` | Tableau natif des résultats (fluide avec des centaines de milliers de lignes) |
| `FouineApp.swift` | Fenêtre, menus, À propos, Sparkle |
| `Localisation.swift` | Textes dans la langue du système |
