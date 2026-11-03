# Manor Lords Co-op

Un mod pour jouer à **Manor Lords à plusieurs sur la même carte, chacun son seigneur et son territoire**.
L'hôte joue sa partie normalement ; un ami la rejoint, choisit une région libre et y fonde son village.
Chacun construit chez soi, et voit en direct les constructions de l'autre.

*English summary: a co-op mod for Manor Lords where each player is a separate lord with their own
region on one shared map. See "Comment ça marche" for the design; PROTOCOL.md for the wire format.*

> **État : version 0.2.0, expérimentale.** Portée sur le build Steam 26185246. Testée en laboratoire
> (deux copies du jeu sur un même PC, pilotées par un robot de test) et par un joueur à la souris sur
> un même PC, **pas encore en vraie partie entre deux PC**. Lisez « Limites connues ».

## Version du jeu

Le mod ne fonctionne qu'avec **une version précise du jeu**, et refuse de démarrer sur une autre :

| | |
|---|---|
| Jeu | Manor Lords, Steam (app 1363080) |
| Version | build Steam 26185246 (Unreal Engine 5.5.4) |
| Exécutable | `ManorLords-Win64-Shipping.exe`, SHA-256 `560451df38cd91134026c25b69539449c570f3163e33bc8c45b4dc20b6952cee` |
| Systèmes | Windows 10/11 64 bits, ou Linux avec Proton |

Les deux joueurs doivent avoir **la même version du jeu et du mod** : à la connexion, l'hôte refuse
un invité dont la version diffère, avec un message clair.

## Installation

1. Décompressez l'archive `ManorLords-Coop-0.2.0.zip` n'importe où.
2. **Windows** : double-cliquez sur `ManorLords-Coop.bat`.
   **Linux (Proton)** : lancez `./manorlords-coop.sh` dans un terminal.
3. L'installateur trouve le jeu, vérifie sa version, installe UE4SS (inclus dans l'archive, version
   figée) et le mod, puis vous pose trois questions : hôte ou invité, adresse de l'hôte, nom de votre
   seigneur.
4. **Linux seulement** : dans Steam, clic droit sur Manor Lords > Propriétés > Options de lancement :
   `WINEDLLOVERRIDES="dwmapi=n,b" %command%` (sans cela, Proton ne charge pas UE4SS).

L'installateur n'écrit que dans le dossier du jeu. Il garde un journal et sait **désinstaller**
(relancez-le et choisissez « désinstaller »).

## Jouer

**L'hôte**

1. Lancez le jeu, commencez une nouvelle partie ou chargez la vôtre.
2. Dès que la partie est chargée, le mod ouvre le port **27015 (TCP)** et attend un invité.
3. Votre ami doit pouvoir joindre ce port : redirection de port sur la box, ou un réseau privé
   virtuel (Tailscale, ZeroTier...). Sur Windows, autorisez le jeu dans le pare-feu.

**L'invité**

1. Lancez le jeu et restez au menu principal.
2. Le mod se connecte à l'hôte, reçoit sa partie (quelques secondes) et la charge.
3. Il choisit une région libre (celle de `region =` dans `config.txt` si elle est libre, sinon la
   première libre) et y fonde votre village. Vous jouez ensuite votre seigneur normalement.

Le fichier `ue4ss\Mods\ManorLordsCoop\run\status.txt` (dans le dossier `Binaries\Win64` du jeu)
dit à chaque instant où en est le mod : connexion, monde envoyé, région prise, erreurs.

### Reprendre une partie un autre jour

L'hôte sauvegarde normalement. Le seigneur de l'invité fait partie de cette sauvegarde (chez l'hôte,
c'est une copie passive qui lui appartient toujours). Un autre jour, l'hôte charge cette partie,
l'invité se connecte **avec le même nom de seigneur** : il reçoit le monde et reprend son seigneur,
sa région et ses bâtiments au lieu de fonder un nouveau village. L'hôte retient les noms de ses
invités dans `ue4ss\Mods\ManorLordsCoop\run\guests.txt`.

### Réglages (`ue4ss\Mods\ManorLordsCoop\config.txt`)

```
role = host            # host (hôte), join (invité) ou off (mod désactivé)
address = 1.2.3.4      # invité : adresse de l'hôte
port = 27015
lord = Aldric          # le nom de votre seigneur (différent de celui de l'autre joueur)
region =               # invité : région souhaitée (nom ou étiquette), facultatif
```

## Premier essai à deux (liste à suivre)

1. Les deux : même version du jeu (l'installateur le vérifie), même archive du mod.
2. L'hôte : ouvrez le port 27015 TCP (ou installez Tailscale/ZeroTier des deux côtés), lancez une
   **nouvelle partie**, attendez d'être en jeu.
3. L'invité : `role = join`, `address = <adresse de l'hôte>`, lancez le jeu, restez au menu.
4. Vérifiez dans `run/status.txt` des deux côtés : « connected », « world sent » / « world
   received », « settled ... » chez l'invité, « ... joined in ... » chez l'hôte.
5. Chacun pose : une maison (parcelle d'habitation), un champ, une route, un bâtiment simple, puis
   en démolit un. Regardez si l'autre le voit apparaître (quelques secondes).
6. L'hôte sauvegarde, vous quittez tous les deux, l'hôte recharge, l'invité revient avec le même
   nom : il doit retrouver son village.
7. Si quelque chose ne va pas, envoyez ces fichiers (dossier `ue4ss\Mods\ManorLordsCoop\run\` et
   `ue4ss\UE4SS.log` du dossier `Binaries\Win64` du jeu), et, en cas de plantage, le dernier dossier
   de `%LOCALAPPDATA%\ManorLords\Saved\Crashes\`.

## Comment ça marche

- Chaque joueur est **maître de son seigneur** : sa région, ses bâtiments, ses champs, ses routes.
  Chez l'autre joueur, ce seigneur existe aussi, mais en **copie passive** (son IA est coupée) que
  le mod tient à jour à partir de messages : « bâtiment de tel type posé ici », « champ de telle
  forme », « route par ces points », « bâtiment démoli ».
- L'hôte est maître du reste du monde : le baron, les bandits, le calendrier. Chez l'invité, le
  baron et les bandits sont passifs et suivent les constructions de l'hôte.
- La vitesse est fixe (x1) pour les deux : pas de pause, pas d'accélération.
- Les deux parties ne calculent pas tout pareil (le jeu n'est pas déterministe) : les villageois
  de l'autre joueur sont simulés chez vous et peuvent ne pas être exactement au même endroit que
  chez lui. Ce qui compte (qui possède quoi, quels bâtiments, où) est synchronisé.

## Changements en 0.2.0

- **Portage sur le build Steam 26185246** : les huit fonctions natives et tous les décalages mémoire
  ont été retrouvés dans le nouvel exécutable (méthode et tableau complet : `docs/PORTING.md`). Le
  prologue de `commitRoad` a changé : le crochet y prend désormais 15 octets.
- **Plantage corrigé** : `commitField` et `commitRoad` renvoient l'objet qu'ils créent, et le jeu
  s'en sert. Les crochets 0.1.0 étaient déclarés `void` : après une vraie route tracée à la souris,
  l'écriture du rapport écrasait `rax` et le jeu recevait un pointeur invalide (plantage plus tard,
  en survolant un bâtiment). Les crochets renvoient maintenant la valeur d'origine.
- **Sécurité** : seul un invité accepte des fichiers, et seulement ceux du monde partagé
  (`coop_world*`). Avant, un pair pouvait écraser n'importe quelle sauvegarde.
- Le journal (`status.txt`) note la version du jeu chez l'hôte et chaque démolition reçue.
- Laboratoire : `test/run-pair.ps1` (Windows, deux copies du jeu sur un PC), scénarios `manual`
  (un humain joue, le mod journalise le survol) et `hoverrm` (survol + démolition à distance),
  commandes natives `hover` et `peek`. Le comptage `roads` ignore les routes fantômes à l'origine.
- Construction sous Windows sans SDK : `native/build.ps1` (clang et lld de Zig).

## Limites connues (0.2.0)

- **Jamais testé entre deux vrais PC** : les tests ont été faits sur un seul PC (robot, puis un
  joueur à la souris). Le premier essai réel servira à trouver ce qui manque.
- **Connexion directe uniquement** (adresse IP + port) : pas encore d'invitation Steam.
- **Deux joueurs** seulement (un invité).
- Routes, champs, parcelles d'habitation et bâtiments posés **à la souris** ont été reproduits dans
  les deux sens lors d'un essai sur un PC. La correction du plantage décrit plus haut attend encore
  la confirmation d'un deuxième essai à la souris.
- Un plantage **intermittent** a été vu une fois (sur une dizaine d'essais), au moment où le script
  de test ferme de force les fenêtres du jeu : la boucle des décalques de route des bâtiments
  proches (`closeBuildings`) a trouvé une entrée nulle dans `roadDecals`. Aucun état anormal n'a été
  trouvé pendant le jeu ; on ne sait pas encore si le jeu sans mod fait de même à la fermeture forcée.
- Pas encore synchronisés : avancement des chantiers (un bâtiment de l'autre joueur apparaît
  directement terminé chez vous), **améliorations** de bâtiments, extensions de parcelles (jardins),
  stocks, villageois, armées, raids, commerce entre joueurs, trésor et influence.
- Les routes construites par l'IA (baron) ne sont pas reproduites chez l'invité.
- Le jeu lui-même double parfois les points d'un champ au chargement d'une sauvegarde (vu sans le
  mod aussi) : sans conséquence connue.
- Au chargement d'une sauvegarde, le jeu donne parfois au joueur des bâtiments neutres de la carte ;
  à la connexion, l'invité recale tous les propriétaires sur ceux de l'hôte, ce qui corrige cela.
- Le mod contient un robot de test, inactif chez les joueurs (il ne s'active qu'avec une variable
  d'environnement du laboratoire).

## Construire depuis les sources

- `native/build.sh` : construit `coopnative.dll` avec `clang-cl` et `lld-link` (aucune dépendance
  à la bibliothèque C ni au SDK Windows). Sous Windows : `native/build.ps1` (Zig, variable `ZIG`).
- `lua/ManorLordsCoop/` : le mod Lua pour UE4SS.
- `release.sh` : construit l'archive de distribution.
- `docs/PORTING.md` et `tools/re/` : comment retrouver fonctions et décalages après une mise à jour
  du jeu.

Les tests (deux copies du jeu sans fenêtre, robot de test, comparaison automatique) vivent dans le
dépôt de l'auteur et sont décrits dans le compte-rendu
[coop-anything](https://github.com/cranebeaker/coop-anything) (`games/manor-lords/`). Sous Windows,
`test/run-pair.ps1 <scénario>` lance l'hôte et l'invité sur le même PC et compare leurs lignes STATE.

## Licence

MIT (voir `LICENSE`). UE4SS est distribué sous sa propre licence MIT (`THIRD_PARTY/UE4SS-LICENSE`).
Ce mod n'est ni affilié à Slavic Magic ni à Hooded Horse.
