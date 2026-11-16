#!/bin/bash
# =====================================================================
#  config-dns.sh : serveur DNS BIND9 (zone directe + zone inverse)
#  Domaine du labo : ingSALI-infra.lan (modifiable a la premiere question)
#
#  CE QUE FAIT LE SCRIPT :
#    1. pose des questions (domaine, IP du serveur, noms...) avec des valeurs par defaut
#    2. installe BIND9 (le logiciel serveur DNS)
#    3. declare 2 zones : directe (nom -> IP) et inverse (IP -> nom)
#    4. cree les 2 fichiers de zone avec les enregistrements NS, A, CNAME, PTR
#    5. verifie la syntaxe, demarre le service
#    6. (option) fait distribuer ce DNS aux clients par le DHCP
#    7. VERIFIE tout automatiquement (service, zones, dig directs/inverses...)
#
#  Usage : sudo -i   puis   ./config-dns-prof.sh
#  Le script peut etre relance sans danger (il reecrit les fichiers).
# =====================================================================

# --- Preparation -----------------------------------------------------
[ "$(id -u)" -eq 0 ] || { echo "Lancez en root : sudo ./config-dns-prof.sh"; exit 1; }   # installer des paquets et ecrire dans /etc exige root
export LC_ALL=C DEBIAN_FRONTEND=noninteractive      # sorties des commandes en anglais (analyse fiable) ; apt ne pose pas de questions
export PATH=$PATH:/usr/sbin:/sbin                   # named-checkconf, rndc... se trouvent dans /usr/sbin

R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[36m'; N=$'\e[0m'   # codes couleur : rouge, vert, jaune, cyan, normal
PASS=0; FAIL=0                                      # compteurs des tests reussis et rates

OPT=/etc/bind/named.conf.options                    # fichier des options globales de BIND
LOC=/etc/bind/named.conf.local                      # fichier ou l'on declare nos zones
ZDIR=/etc/bind/zones                                # dossier qui contiendra nos fichiers de zone
DHCPC=/etc/dhcp/dhcpd.conf                          # configuration du serveur DHCP (si present)

# --- Fonctions d'affichage et d'interaction ----------------------------
step()  { echo; echo "${B}=====  ETAPE $1 : $2  =====${N}"; }   # affiche le titre d'une etape en cyan
say()   { echo "   ${Y}->${N} $*"; }                            # affiche une explication (ce que le script fait et pourquoi)
ok()    { echo "   ${G}[ OK ]${N} $1"; PASS=$((PASS+1)); }      # test reussi : ligne verte et compteur +1
ko()    { echo "   ${R}[ KO ]${N} $1"; FAIL=$((FAIL+1)); [ -n "$2" ] && echo "          conseil : $2"; return 0; }   # test rate : ligne rouge, compteur +1, astuce
ask()   { local v; read -rp "   ? $1 [$2] : " v; echo "${v:-$2}"; }   # pose une question, renvoie la reponse (ou la valeur par defaut si Entree)
yn()    { local v; read -rp "   ? $1 [$2] : " v; v=${v:-$2}; [[ "$v" =~ ^[oOyY]$ ]]; }   # question oui/non : vrai si o/O/y/Y
pause() { [ "$STEPMODE" = 1 ] && read -rp "   (Entree pour continuer) " _; }   # pause entre les etapes si le mode pas-a-pas est actif
lc()    { echo "$1" | tr 'A-Z' 'a-z'; }                         # met en minuscules (le DNS ne distingue pas majuscules/minuscules)
valid_ip() {                                                    # verifie qu'une chaine est une IPv4 correcte
  local o; [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1   # 4 nombres separes par des points
  for o in ${1//./ }; do [ "$o" -le 255 ] || return 1; done          # chaque nombre doit etre <= 255
}
ask_ip() { local v; while true; do v=$(ask "$1" "$2"); valid_ip "$v" && { echo "$v"; return; }; echo "   ${R}IP invalide, recommencez.${N}" >&2; done; }   # redemande tant que l'IP est invalide
chk()   { local d=$1 h=$2; shift 2; if "$@" >/dev/null 2>&1; then ok "$d"; else ko "$d" "$h"; fi; }   # execute une commande : OK si elle reussit
eq()    { if [ "$(lc "$2")" = "$(lc "$3")" ]; then ok "$1 = $3"; else ko "$1" "attendu '$2', obtenu '${3:-rien}'"; fi; }   # compare deux valeurs (sans tenir compte de la casse)
q()     { dig +short +time=3 +tries=1 "$@" 2>/dev/null; }       # dig en mode court avec delai limite (evite les attentes)

# =====================================================================
#  ETAPE 0 : presentation
# =====================================================================
clear                                                           # efface l'ecran pour une presentation propre
echo "${B}=================================================================${N}"
echo "${B}   CONFIGURATION DU SERVEUR DNS (BIND9) : zone directe + inverse${N}"
echo "${B}=================================================================${N}"
echo "   Un serveur DNS traduit un NOM en adresse IP (zone directe)"
echo "   et une ADRESSE IP en nom (zone inverse)."
echo
yn "Mode pas-a-pas (pause apres chaque etape, pratique pour expliquer) ?" "O" && STEPMODE=1 || STEPMODE=0   # active ou non les pauses

# =====================================================================
#  ETAPE 1 : questions
# =====================================================================
step 1 "Parametres du serveur DNS"
say "Appuyez sur Entree pour garder la valeur proposee entre crochets."
while true; do                                                  # boucle jusqu'a obtenir un domaine valide
  DOMAIN=$(ask "Nom de domaine" "ingSALI-infra.lan")            # domaine gere par ce serveur
  [[ "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && "$DOMAIN" == *.* ]] && break   # lettres/chiffres/tirets et au moins un point
  echo "   ${R}Domaine invalide (exemple : monlabo.lan).${N}"
done
NS_NAME=$(ask "Nom du serveur DNS (sans le domaine)" "ns")      # devient ns.<domaine>
HOST_REC=$(ask "Nom de la machine serveur a declarer aussi (vide = aucun)" "srvm01")   # enregistrement A supplementaire pour le serveur
SERVER_IP=$(ask_ip "Adresse IP du serveur DNS (la carte NAT du Master)" "192.168.100.100")   # IP renvoyee pour ns, www, etc.
FWD=$(ask_ip "Serveur DNS de secours pour Internet (passerelle NAT VMware)" "192.168.100.2")   # forwarder : DNS qui resout le reste d'Internet
if yn "Declarer aussi le Slave dans le DNS ?" "N"; then         # option : enregistrement pour le serveur de secours
  SLAVE_REC=$(ask "Nom du Slave" "srvs01")                      # nom de la machine Slave
  SLAVE_IP=$(ask_ip "Adresse IP du Slave" "192.168.100.200")    # IP du Slave
else
  SLAVE_REC=""; SLAVE_IP=""                                     # pas de Slave a declarer
fi

IFS=. read -r O1 O2 O3 O4 <<< "$SERVER_IP"                      # decoupe l'IP du serveur en 4 octets O1.O2.O3.O4
REV_ZONE="$O3.$O2.$O1.in-addr.arpa"                                # nom de la zone inverse : 3 premiers octets a l'envers + in-addr.arpa
ZF_DIRECT="$ZDIR/db.$DOMAIN"                                    # fichier de la zone directe
ZF_REV="$ZDIR/db.$O1.$O2.$O3"                                      # fichier de la zone inverse
SERIAL="$(date +%Y%m%d)01"                                      # numero de serie de zone (AAAAMMJJ + 01) : doit augmenter a chaque modification
FQDN_NS="$NS_NAME.$DOMAIN."                                     # nom complet du serveur, avec le point final obligatoire dans un fichier de zone

echo
echo "   ${Y}Recapitulatif :${N}"
echo "     Domaine ........... $DOMAIN"
echo "     Serveur DNS ....... $FQDN_NS -> $SERVER_IP"
echo "     Zone directe ...... $DOMAIN   (fichier $ZF_DIRECT)"
echo "     Zone inverse ...... $REV_ZONE   (fichier $ZF_REV)"
echo "     Forwarder ......... $FWD"
[ -n "$SLAVE_REC" ] && echo "     Slave ............. $SLAVE_REC.$DOMAIN -> $SLAVE_IP"
yn "Lancer la configuration avec ces valeurs ?" "O" || { echo "Annule."; exit 0; }   # derniere confirmation avant de modifier le systeme
pause

# =====================================================================
#  ETAPE 2 : installation
# =====================================================================
step 2 "Installation de BIND9"
say "BIND9 est le serveur DNS le plus utilise. 'bind9-utils' fournit named-checkconf/checkzone, 'bind9-dnsutils' fournit dig."
apt-get update -qq                                              # met a jour la liste des paquets (sans afficher le detail)
apt-get install -y -qq bind9 bind9-utils bind9-dnsutils >/dev/null 2>&1 || { echo "${R}Installation impossible : verifiez l'acces Internet (ping 8.8.8.8).${N}"; exit 1; }   # installe les 3 paquets ; stop si echec
ok "BIND9 installe ($(named -v 2>/dev/null))"                   # affiche la version installee
pause

# =====================================================================
#  ETAPE 3 : sauvegarde
# =====================================================================
step 3 "Sauvegarde des fichiers de configuration"
BK=/root/backup-dns-$(date +%H%M%S)                             # dossier de sauvegarde unique (heure de l'execution)
mkdir -p "$BK"                                                  # cree le dossier
cp "$OPT" "$LOC" "$BK/" 2>/dev/null                             # copie les deux fichiers BIND avant de les modifier
[ -f "$DHCPC" ] && cp "$DHCPC" "$BK/"                           # copie aussi la config DHCP si elle existe
say "Copies dans $BK : on peut revenir en arriere en cas de probleme."
pause

# =====================================================================
#  ETAPE 4 : options globales
# =====================================================================
step 4 "Options globales de BIND ($OPT)"
say "On definit : qui peut interroger le serveur, qui a droit a la resolution recursive, et le forwarder."
cat > "$OPT" <<EOF
options {
	directory "/var/cache/bind";         // dossier de travail de BIND
	listen-on { any; };                  // ecoute sur toutes les cartes IPv4 (NAT et 3 LAN)
	listen-on-v6 { none; };              // pas d'IPv6 dans ce labo
	allow-query { any; };                // tout le monde peut poser une question
	recursion yes;                       // le serveur peut chercher la reponse a la place du client
	allow-recursion { localhost; localnets; };   // ...mais seulement pour la machine et les reseaux directement connectes
	forwarders { $FWD; };                // les noms inconnus (Internet) sont envoyes a ce DNS
	dnssec-validation no;                // pas de validation DNSSEC (inutile dans un labo, evite des erreurs)
};
EOF
ok "Options ecrites"
pause

# =====================================================================
#  ETAPE 5 : declaration des zones
# =====================================================================
step 5 "Declaration des deux zones ($LOC)"
say "Une zone = un domaine dont CE serveur fait autorite. 'type master' = il detient l'original des donnees."
cat > "$LOC" <<EOF
// Zone directe : nom -> adresse IP
zone "$DOMAIN" {
	type master;                         // ce serveur est la source de verite
	file "$ZF_DIRECT";                   // fichier contenant les enregistrements
};

// Zone inverse : adresse IP -> nom
zone "$REV_ZONE" {
	type master;
	file "$ZF_REV";
};
EOF
ok "Zones declarees : $DOMAIN et $REV_ZONE"
pause

# =====================================================================
#  ETAPE 6 : fichiers de zone
# =====================================================================
step 6 "Creation des fichiers de zone"
mkdir -p "$ZDIR"                                                # cree le dossier des fichiers de zone
say "Zone directe : $ZF_DIRECT"
cat > "$ZF_DIRECT" <<EOF
\$TTL    604800                          ; duree de vie par defaut des reponses (7 jours)
@       IN      SOA     $FQDN_NS admin.$DOMAIN. (
                        $SERIAL          ; Serial : DOIT augmenter a chaque modification
                        604800           ; Refresh : frequence de verification par un esclave
                        86400            ; Retry : delai avant nouvel essai si echec
                        2419200          ; Expire : un esclave abandonne la zone apres ce delai
                        604800 )         ; Negative cache : duree de memorisation d'un "n'existe pas"
;
@       IN      NS      $FQDN_NS         ; serveur de noms de la zone
@       IN      A       $SERVER_IP       ; le domaine lui-meme pointe vers le serveur
$NS_NAME      IN      A       $SERVER_IP       ; enregistrement A : nom du serveur DNS -> IP
www     IN      A       $SERVER_IP       ; www -> IP
mail    IN      CNAME   www              ; mail est un alias (CNAME) de www
EOF
[ -n "$HOST_REC" ] && echo "$HOST_REC	IN	A	$SERVER_IP	; nom de la machine serveur -> IP" >> "$ZF_DIRECT"   # ajoute la machine serveur si demandee
[ -n "$SLAVE_REC" ] && echo "$SLAVE_REC	IN	A	$SLAVE_IP	; machine Slave -> IP" >> "$ZF_DIRECT"           # ajoute le Slave si demande
sed -n '1,40p' "$ZF_DIRECT" | sed 's/^/        | /'             # montre le fichier a l'ecran avec un petit decalage

say "Zone inverse : $ZF_REV"
cat > "$ZF_REV" <<EOF
\$TTL    604800
@       IN      SOA     $FQDN_NS admin.$DOMAIN. (
                        $SERIAL          ; Serial
                        604800           ; Refresh
                        86400            ; Retry
                        2419200          ; Expire
                        604800 )         ; Negative cache
;
@       IN      NS      $FQDN_NS         ; serveur de noms de la zone inverse
$O4      IN      PTR     $FQDN_NS         ; PTR : dernier octet de l'IP ($O4) -> nom du serveur
EOF
if [ -n "$SLAVE_REC" ] && [ "${SLAVE_IP%.*}" = "$O1.$O2.$O3" ]; then   # le Slave a un PTR seulement s'il est dans le meme reseau /24
  echo "${SLAVE_IP##*.}	IN	PTR	$SLAVE_REC.$DOMAIN.	; IP du Slave -> nom" >> "$ZF_REV"
fi
sed -n '1,40p' "$ZF_REV" | sed 's/^/        | /'                 # montre le fichier a l'ecran

chown -R root:bind "$ZDIR"                                      # le groupe 'bind' doit pouvoir lire les fichiers
chmod 755 "$ZDIR"; chmod 644 "$ZDIR"/*                          # dossier traversable, fichiers lisibles
ok "Fichiers de zone crees"
pause

# =====================================================================
#  ETAPE 7 : verification de syntaxe AVANT de demarrer
# =====================================================================
step 7 "Verification de la syntaxe"
say "On teste les fichiers avant de relancer le service : une erreur ici evite de casser le DNS."
ERR=0                                                           # passe a 1 si une verification echoue
named-checkconf && ok "named-checkconf : configuration valide" || { ko "named-checkconf"; ERR=1; }   # verifie named.conf*
named-checkzone "$DOMAIN" "$ZF_DIRECT" >/dev/null && ok "named-checkzone : zone $DOMAIN valide" || { ko "zone $DOMAIN"; ERR=1; }   # verifie la zone directe
named-checkzone "$REV_ZONE" "$ZF_REV" >/dev/null && ok "named-checkzone : zone $REV_ZONE valide" || { ko "zone $REV_ZONE"; ERR=1; }   # verifie la zone inverse
if [ $ERR -eq 1 ]; then                                         # en cas d'erreur : on restaure et on arrete
  echo "${R}Erreur de syntaxe : restauration des sauvegardes.${N}"
  cp "$BK/$(basename $OPT)" "$OPT"; cp "$BK/$(basename $LOC)" "$LOC"; exit 1
fi
pause

# =====================================================================
#  ETAPE 8 : demarrage du service
# =====================================================================
step 8 "Demarrage du service"
systemctl enable named >/dev/null 2>&1                          # demarrage automatique a chaque boot
systemctl restart named                                         # (re)demarre BIND pour appliquer la configuration
sleep 2                                                         # laisse le temps au service de charger les zones
if systemctl is-active --quiet named; then ok "Service named actif"; else ko "Service named inactif" "journalctl -u named --no-pager | tail -20"; fi
pause

# =====================================================================
#  ETAPE 9 : DHCP (option)
# =====================================================================
step 9 "Distribution du DNS aux clients par le DHCP (optionnel)"
DHCP_DONE=0                                                     # passe a 1 si le DHCP a ete modifie
if [ -f "$DHCPC" ]; then                                        # seulement si ce serveur est aussi le serveur DHCP
  say "Sans cela, les clients gardent l'ancien DNS et ne connaissent pas $DOMAIN."
  if yn "Faire distribuer ce DNS et le domaine par le DHCP ?" "O"; then
    LANS=$(ask "Prefixes des reseaux LAN (separes par des espaces)" "10.10.10 20.20.20 30.30.30")   # un DNS par sous-reseau
    LAN_OCT=$(ask "Dernier octet du serveur sur chaque LAN" "254")                                   # le Master est .254 sur chaque LAN
    sed -i '/^option domain-name "/d' "$DHCPC"                  # supprime une ancienne ligne domain-name
    sed -i "1i option domain-name \"$DOMAIN\";" "$DHCPC"        # ajoute le domaine en tete du fichier (suffixe de recherche des clients)
    for p in $LANS; do                                          # pour chaque reseau LAN
      pe=${p//./\\.}                                            # echappe les points pour que sed les prenne litteralement
      sed -i "/subnet ${pe}\.0[[:space:]]/,/}/ s/option domain-name-servers .*/option domain-name-servers $p.$LAN_OCT;/" "$DHCPC"   # remplace le DNS distribue dans ce sous-reseau
    done
    if dhcpd -t -cf "$DHCPC" >/dev/null 2>&1; then              # le fichier DHCP modifie est-il valide ?
      systemctl restart isc-dhcp-server && { ok "DHCP mis a jour et redemarre"; DHCP_DONE=1; }   # applique
    else
      ko "dhcpd.conf invalide : restauration" "dhcpd -t -cf $DHCPC"; cp "$BK/dhcpd.conf" "$DHCPC"   # annule si erreur
    fi
  fi
else
  say "Pas de $DHCPC sur cette machine : etape ignoree."
fi
pause

# =====================================================================
#  ETAPE 10 : VERIFICATION COMPLETE
# =====================================================================
step 10 "VERIFICATION AUTOMATIQUE DE LA CONFIGURATION"

echo "   ${B}-- Service --${N}"
chk "Service named actif" "systemctl status named" systemctl is-active --quiet named          # le processus tourne
chk "Service named active au demarrage" "systemctl enable named" systemctl is-enabled --quiet named   # il demarrera apres un reboot
chk "Ecoute sur le port 53 (UDP)" "ss -ulnp | grep :53" bash -c "ss -uln | grep -q ':53 '"   # port DNS en UDP
chk "Ecoute sur le port 53 (TCP)" "ss -tlnp | grep :53" bash -c "ss -tln | grep -q ':53 '"   # port DNS en TCP

echo "   ${B}-- Fichiers --${N}"
chk "named-checkconf" "corriger $OPT ou $LOC" named-checkconf                                 # configuration globale valide
chk "Zone $DOMAIN valide" "named-checkzone $DOMAIN $ZF_DIRECT" named-checkzone "$DOMAIN" "$ZF_DIRECT"   # zone directe valide
chk "Zone $REV_ZONE valide" "named-checkzone $REV_ZONE $ZF_REV" named-checkzone "$REV_ZONE" "$ZF_REV"   # zone inverse valide
chk "Fichiers de zone lisibles par l'utilisateur bind" "chmod 644 $ZDIR/*" bash -c "runuser -u bind -- test -r '$ZF_DIRECT' && runuser -u bind -- test -r '$ZF_REV'"   # BIND tourne sous l'utilisateur 'bind'

echo "   ${B}-- Zones chargees --${N}"
chk "SOA de $DOMAIN repond" "verifier la declaration de zone" bash -c "[ -n \"\$(dig +short +time=3 +tries=1 @127.0.0.1 $DOMAIN SOA)\" ]"   # la zone est servie
chk "SOA de $REV_ZONE repond" "verifier la declaration de zone" bash -c "[ -n \"\$(dig +short +time=3 +tries=1 @127.0.0.1 $REV_ZONE SOA)\" ]"   # la zone inverse est servie
if dig +noall +comments +time=3 +tries=1 @127.0.0.1 "www.$DOMAIN" 2>/dev/null | grep -q "flags:.* aa"; then   # drapeau 'aa' = authoritative answer
  ok "Reponse AUTORITAIRE (flag aa) : ce serveur fait autorite sur $DOMAIN"
else ko "Reponse non autoritaire" "la zone n'est pas chargee"; fi

echo "   ${B}-- Resolution directe (nom -> IP) --${N}"
eq "$NS_NAME.$DOMAIN"  "$SERVER_IP" "$(q @127.0.0.1 $NS_NAME.$DOMAIN)"     # enregistrement A du serveur DNS
eq "www.$DOMAIN"       "$SERVER_IP" "$(q @127.0.0.1 www.$DOMAIN)"          # enregistrement A de www
eq "$DOMAIN (racine)"  "$SERVER_IP" "$(q @127.0.0.1 $DOMAIN A)"            # le domaine lui-meme
if q @127.0.0.1 "mail.$DOMAIN" | grep -qi "^www.$(lc "$DOMAIN")\.$" && q @127.0.0.1 "mail.$DOMAIN" | grep -q "$SERVER_IP"; then   # le CNAME renvoie l'alias puis l'IP
  ok "mail.$DOMAIN est un alias (CNAME) de www -> $SERVER_IP"
else ko "mail.$DOMAIN (CNAME)" "verifier la ligne CNAME dans $ZF_DIRECT"; fi
[ -n "$HOST_REC" ] && eq "$HOST_REC.$DOMAIN" "$SERVER_IP" "$(q @127.0.0.1 $HOST_REC.$DOMAIN)"          # machine serveur
[ -n "$SLAVE_REC" ] && eq "$SLAVE_REC.$DOMAIN" "$SLAVE_IP" "$(q @127.0.0.1 $SLAVE_REC.$DOMAIN)"        # machine Slave

echo "   ${B}-- Resolution inverse (IP -> nom) --${N}"
eq "PTR de $SERVER_IP" "$FQDN_NS" "$(q @127.0.0.1 -x $SERVER_IP)"          # la zone inverse repond
[ -n "$SLAVE_REC" ] && [ "${SLAVE_IP%.*}" = "$O1.$O2.$O3" ] && eq "PTR de $SLAVE_IP" "$SLAVE_REC.$DOMAIN." "$(q @127.0.0.1 -x $SLAVE_IP)"   # PTR du Slave

echo "   ${B}-- Cas d'erreur et Internet --${N}"
if dig +time=3 +tries=1 @127.0.0.1 "inexistant.$DOMAIN" 2>/dev/null | grep -q NXDOMAIN; then   # un nom absent doit renvoyer NXDOMAIN
  ok "Un nom inexistant renvoie bien NXDOMAIN"
else ko "NXDOMAIN attendu pour un nom inexistant"; fi
[ -n "$(q @127.0.0.1 deb.debian.org)" ] && ok "Resolution externe OK via le forwarder $FWD (deb.debian.org)" || ko "Resolution externe" "verifier la carte NAT et $FWD"   # le forwarder fonctionne

echo "   ${B}-- Le serveur repond sur chacune de ses adresses --${N}"
for a in $(ip -4 -o a | awk '{print $4}' | cut -d/ -f1 | grep -v '^127\.'); do   # chaque IP locale hors loopback
  eq "www.$DOMAIN via $a" "$SERVER_IP" "$(q @$a www.$DOMAIN)"               # interroge le serveur par cette interface
done

if [ $DHCP_DONE -eq 1 ]; then                                   # verification DHCP seulement si on l'a modifie
  echo "   ${B}-- DHCP --${N}"
  chk "dhcpd.conf valide" "dhcpd -t -cf $DHCPC" dhcpd -t -cf "$DHCPC"             # syntaxe correcte
  chk "Service isc-dhcp-server actif" "systemctl status isc-dhcp-server" systemctl is-active --quiet isc-dhcp-server   # DHCP en marche
  grep -qi "option domain-name \"$DOMAIN\"" "$DHCPC" && ok "Domaine $DOMAIN distribue aux clients" || ko "domain-name absent du DHCP"   # suffixe de recherche
  grep -n "domain-name-servers" "$DHCPC" | sed 's/^/        | /'                    # affiche les DNS distribues
fi

echo
if [ $FAIL -eq 0 ]; then echo "   ${G}RESULTAT : $PASS verifications OK, aucun echec. Le DNS est correctement configure.${N}"   # bilan positif
else echo "   ${R}RESULTAT : $PASS OK, $FAIL KO. Corrigez les lignes KO puis relancez le script.${N}"; fi   # bilan avec erreurs

# =====================================================================
#  ETAPE 11 : commandes de test cote clients
# =====================================================================
step 11 "A tester maintenant depuis les clients (captures pour le compte rendu)"
cat <<EOF
   ${Y}Client Linux${N} :
      resolvectl status                    (DNS attendu : le Master)
      dig www.$DOMAIN +short               -> $SERVER_IP
      dig -x $SERVER_IP +short             -> $FQDN_NS
      ping -c 2 www.$DOMAIN
   ${Y}Client Windows (cmd)${N} :
      ipconfig /release  puis  ipconfig /renew  puis  ipconfig /flushdns
      ipconfig /all                        (DNS Servers + suffixe $DOMAIN)
      nslookup www.$DOMAIN
      nslookup $SERVER_IP
      ping www.$DOMAIN
   ${Y}Sur le serveur${N} : relancer ce script pour rejouer toutes les verifications.
   Sauvegardes de l'ancienne configuration : $BK
EOF
