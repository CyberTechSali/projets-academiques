#!/bin/bash
# =====================================================================
#  LABO ingSALI-infra.lan : DNS Maitre/Esclave + DHCP + clients
#  Debian 13 / BIND9 / isc-dhcp-server / systemd-networkd
#
#  Ce script unique permet de :
#    - configurer le Master, le Slave et les clients Linux / IoT
#    - verifier chaque machine apres configuration
#    - tester la replication automatique et la panne du Master
#    - afficher le guide de verification a executer sous Windows
#  AVANT toute configuration, il liste les interfaces reseau
#  existantes (nom, etat, MAC, IP) pour eviter les erreurs de nom.
#
#  Usage : sudo ./labo-dns.sh
# =====================================================================

# Le script doit etre lance en root (installation de paquets, fichiers /etc)
[ "$EUID" -ne 0 ] && { echo "Lancez avec sudo : sudo ./labo-dns.sh"; exit 1; }
# LC_ALL=C : sorties des commandes en anglais (analyse fiable) ; DEBIAN_FRONTEND : apt sans questions
export LC_ALL=C DEBIAN_FRONTEND=noninteractive
# Ajoute /usr/sbin et /sbin au PATH (named-checkconf, dhcpd, sysctl... y sont installes)
export PATH=$PATH:/usr/sbin:/sbin

# Codes couleur du terminal : rouge, vert, jaune, cyan, retour a la normale
R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[36m'; N=$'\e[0m'
# Compteurs des tests reussis / echoues (remis a zero apres chaque resume)
PASS=0; FAIL=0
# Fichiers de configuration BIND et DHCP utilises partout dans le script
OPT=/etc/bind/named.conf.options   # options globales de BIND
LOC=/etc/bind/named.conf.local     # declaration des zones
DHCPC=/etc/dhcp/dhcpd.conf         # configuration du serveur DHCP

# =====================================================================
#                      OUTILS D'AFFICHAGE ET DE TEST
# =====================================================================
# ask "question" "defaut" : pose une question, renvoie la reponse (ou le defaut si Entree)
ask()   { local v; read -rp "$1 [$2] : " v; echo "${v:-$2}"; }
# yn "question" "O|N" : question oui/non, renvoie "vrai" si la reponse est o/O/y/Y
yn()    { local v; read -rp "$1 [$2] : " v; v=${v:-$2}; [[ "$v" =~ ^[oOyY]$ ]]; }
# title "texte" : affiche un titre de section en cyan
title() { echo; echo "${B}=== $1 ===${N}"; }
# ok "texte" : affiche un test reussi en vert et incremente PASS
ok()    { echo " ${G}[ OK ]${N} $1"; PASS=$((PASS+1)); }
# ko "texte" "astuce" : affiche un test rate en rouge, incremente FAIL, affiche l'astuce si fournie
ko()    { echo " ${R}[ KO ]${N} $1"; FAIL=$((FAIL+1)); [ -n "$2" ] && echo "        -> $2"; return 0; }
# info "texte" : simple information en jaune (ni OK ni KO)
info()  { echo " ${Y}[ .. ]${N} $1"; }
# chk "description" "astuce" commande... : OK si la commande reussit, KO sinon
chk()   { local d=$1 h=$2; shift 2; if "$@" >/dev/null 2>&1; then ok "$d"; else ko "$d" "$h"; fi; }
# eq "description" attendu obtenu : OK si les deux valeurs sont identiques
eq()    { if [ "$2" = "$3" ]; then ok "$1 = $3"; else ko "$1" "attendu '$2', obtenu '${3:-rien}'"; fi; }
# has "description" motif texte : OK si le texte contient le motif (sans tenir compte de la casse)
has()   { if echo "$3" | grep -qiE "$2"; then ok "$1"; else ko "$1" "motif '$2' absent de : $(echo $3 | tr '\n' ' ')"; fi; }
# summary : affiche le bilan des tests puis remet les compteurs a zero
summary() {
  echo
  if [ $FAIL -eq 0 ]; then echo "${G}RESULTAT : $PASS tests OK, aucun echec.${N}"             # tout est bon
  else echo "${R}RESULTAT : $PASS OK, $FAIL KO. Corrigez les lignes KO puis relancez la verification.${N}"; fi
  PASS=0; FAIL=0                                                                               # remise a zero
}

# =====================================================================
#                              PARAMETRES
# =====================================================================
# rev "10.10.10" -> "10.10.10.in-addr.arpa" ; rev "192.168.100" -> "100.168.192.in-addr.arpa"
# (nom de la zone inverse : les 3 octets du reseau ecrits a l'envers)
rev() { echo "$1" | awk -F. '{print $3"."$2"."$1".in-addr.arpa"}'; }

# load_params : definit toutes les valeurs de la topologie (une seule fois)
load_params() {
  [ -n "$PARAMS_OK" ] && return                                   # deja charge : on sort
  DOMAIN="ingSALI-infra.lan"                                      # domaine du laboratoire
  M_NAME="srv1-sali";  S_NAME="srv2-sali"                         # noms du Master et du Slave
  LINUX_NAME="linux-client"; IOT_NAME="iot-client"; WIN_NAME="windows-client"   # noms des clients
  L1="10.10.10"; L2="20.20.20"; L3="30.30.30"                     # prefixes des 3 LAN
  M_OCT="254"; S_OCT="253"                                        # dernier octet : Master .254, Slave .253
  M_NAT="192.168.100.100"; S_NAT="192.168.100.200"                # IP NAT du Master et du Slave
  FWD="192.168.100.2"                                             # passerelle NAT VMware = forwarder DNS
  title "Parametres du laboratoire"
  if ! yn "Utiliser toutes les valeurs du schema sans question ?" "O"; then   # mode personnalise
    DOMAIN=$(ask "Domaine" "$DOMAIN")
    M_NAME=$(ask "Nom du Master" "$M_NAME");   S_NAME=$(ask "Nom du Slave" "$S_NAME")
    LINUX_NAME=$(ask "Nom client Linux" "$LINUX_NAME"); IOT_NAME=$(ask "Nom client IoT" "$IOT_NAME")
    WIN_NAME=$(ask "Nom client Windows" "$WIN_NAME")
    L1=$(ask "Prefixe LAN1" "$L1"); L2=$(ask "Prefixe LAN2" "$L2"); L3=$(ask "Prefixe LAN3" "$L3")
    M_OCT=$(ask "Dernier octet du Master sur les LAN" "$M_OCT")
    S_OCT=$(ask "Dernier octet du Slave sur les LAN" "$S_OCT")
    M_NAT=$(ask "IP NAT du Master" "$M_NAT"); S_NAT=$(ask "IP NAT du Slave" "$S_NAT")
    FWD=$(ask "Passerelle NAT / forwarder DNS" "$FWD")
  fi
  LANS=("$L1" "$L2" "$L3")                                        # tableau des 3 prefixes LAN
  MASTER_IP="$L1.$M_OCT"; SLAVE_IP="$L1.$S_OCT"                   # IP du Master et du Slave sur LAN1
  NATNET="${M_NAT%.*}"                                            # prefixe NAT (192.168.100)
  # Zones DNS candidates : zone directe + 3 zones inverses LAN + zone inverse NAT
  CAND=("$DOMAIN" "$(rev $L1)" "$(rev $L2)" "$(rev $L3)" "$(rev $NATNET)")
  # Liste des IP du Slave (3 LAN + NAT) au format BIND "ip; ip; ..." pour allow-transfer / also-notify
  S_LIST=""; for l in "${LANS[@]}"; do S_LIST+="$l.$S_OCT; "; done; S_LIST+="$S_NAT; "
  PARAMS_OK=1                                                     # memorise que c'est charge
}

# =====================================================================
#            DETECTION ET CONTROLE DES INTERFACES RESEAU
# =====================================================================
# role_of_ip IP : indique a quel reseau du labo appartient une adresse
role_of_ip() {
  case "$1" in
    $L1.*) echo "LAN1";;      # adresse du reseau 10.10.10.x
    $L2.*) echo "LAN2";;      # adresse du reseau 20.20.20.x
    $L3.*) echo "LAN3";;      # adresse du reseau 30.30.30.x
    $NATNET.*) echo "NAT";;   # adresse du reseau NAT 192.168.100.x
    *) echo "?";;             # adresse inconnue
  esac
}

# iface_exists NOM : vrai si l'interface existe reellement sur cette machine
iface_exists() { [ -n "$1" ] && [ -d "/sys/class/net/$1" ]; }

# list_interfaces : tableau de toutes les interfaces (sauf lo) avec etat, MAC et IPv4
list_interfaces() {
  printf ' %-10s %-8s %-19s %s\n' "INTERFACE" "ETAT" "MAC" "ADRESSES IPv4 (reseau)"
  local i st mac ips a lst
  for i in $(ls /sys/class/net | grep -v '^lo$'); do                  # chaque interface sauf loopback
    st=$(cat /sys/class/net/$i/operstate 2>/dev/null)                 # etat : up / down
    mac=$(cat /sys/class/net/$i/address 2>/dev/null)                  # adresse MAC
    ips=""
    for a in $(ip -4 -o a show dev "$i" | awk '{print $4}'); do       # chaque adresse IPv4 de l'interface
      ips+="$a($(role_of_ip ${a%/*})) "                               # ajoute l'adresse et son reseau
    done
    printf ' %-10s %-8s %-19s %s\n' "$i" "$st" "$mac" "${ips:-aucune adresse}"
  done
}

# ask_iface "question" "defaut" : demande un nom d'interface et REFUSE un nom qui n'existe pas
ask_iface() {
  local v
  while true; do
    v=$(ask "$1" "$2")                                                # saisie utilisateur
    if iface_exists "$v"; then echo "$v"; return; fi                  # nom valide : on le renvoie
    echo "${R}!! Interface '$v' inexistante. Interfaces disponibles : $(ls /sys/class/net | grep -v '^lo$' | tr '\n' ' ')${N}" >&2
  done
}

# check_expected_ips OCTET IP_NAT : affiche les interfaces puis verifie les IP attendues
check_expected_ips() {
  title "Interfaces reseau detectees sur cette machine"
  list_interfaces                                                     # tableau des interfaces
  echo; echo " Adresses attendues d'apres la topologie :"
  local miss=0 l ip i
  for ip in "$L1.$1" "$L2.$1" "$L3.$1" "$2"; do                       # 3 IP LAN + 1 IP NAT attendues
    i=$(ip -4 -o a | awk -v a="$ip/" 'index($4,a)==1{print $2; exit}')   # interface qui porte cette IP
    if [ -n "$i" ]; then echo "   ${G}presente${N}  $ip ($(role_of_ip $ip)) sur l'interface $i"
    else echo "   ${R}ABSENTE${N}   $ip ($(role_of_ip $ip))"; miss=1; fi   # IP manquante
  done
  if [ $miss -eq 1 ]; then                                            # au moins une IP manque
    echo "${Y} Les IP des serveurs sont definies dans /etc/systemd/network/*.network (scripts precedents).${N}"
    echo "${Y} Corrigez-les (puis systemctl restart systemd-networkd) avant de continuer.${N}"
    yn "Continuer quand meme ?" "N"; return $?                        # laisse le choix a l'utilisateur
  fi
  return 0                                                            # tout est present
}

# =====================================================================
#                          FONCTIONS COMMUNES
# =====================================================================
# need_dig : installe dnsutils (commande dig) si elle manque
need_dig() { command -v dig >/dev/null || apt-get install -y -qq dnsutils >/dev/null 2>&1; }

# set_hostname NOM : change le nom de la machine et la ligne 127.0.1.1 de /etc/hosts
set_hostname() {
  local h=$1
  hostnamectl set-hostname "$h"                                       # nom d'hote permanent
  sed -i '/^127\.0\.1\.1/d' /etc/hosts                                # supprime l'ancienne ligne 127.0.1.1
  if grep -q '^127\.0\.0\.1' /etc/hosts; then                         # si la ligne localhost existe
    sed -i "/^127\.0\.0\.1/a 127.0.1.1 $h.$DOMAIN $h" /etc/hosts      # ajoute la nouvelle juste apres
  else
    echo "127.0.1.1 $h.$DOMAIN $h" >> /etc/hosts                      # sinon l'ajoute a la fin
  fi
  echo " Hostname -> $h"
}

# regen_machine_id : donne un nouvel identifiant unique a la machine (indispensable apres un clone)
regen_machine_id() {
  rm -f /etc/machine-id /var/lib/dbus/machine-id                      # supprime l'ancien identifiant
  systemd-machine-id-setup >/dev/null                                 # en genere un nouveau
  mkdir -p /var/lib/dbus; ln -sf /etc/machine-id /var/lib/dbus/machine-id   # lien utilise par D-Bus
  echo " Nouveau machine-id : $(cat /etc/machine-id)"
}

# serial_of SERVEUR ZONE : renvoie le numero de serie SOA d'une zone chez un serveur DNS
serial_of() { dig +short +time=3 +tries=1 @"$1" "$2" SOA 2>/dev/null | awk '{print $3}'; }

# bump_serial FICHIER : incremente le numero de serie (10 chiffres AAAAMMJJNN) d'un fichier de zone
bump_serial() {
  local f=$1 s n today
  s=$(grep -oP '(?<![0-9])[0-9]{10}(?![0-9])' "$f" | head -1)        # 1er nombre de 10 chiffres = serial
  [ -z "$s" ] && { echo "   !! serial introuvable dans $f (a modifier a la main)"; return 1; }
  today="$(date +%Y%m%d)01"                                           # serial minimal du jour
  if [ "$s" -ge "$today" ]; then n=$((s+1)); else n=$today; fi        # +1 si deja >= aujourd'hui
  sed -i "0,/$s/s//$n/" "$f"                                          # remplace la 1re occurrence
  echo "   serial $s -> $n"
}

# zonefile_of ZONE : lit dans named.conf.local le fichier associe a une zone (chemin absolu)
zonefile_of() {
  local f
  f=$(awk -v z="$1" '
    $0 ~ "zone[ \t]+\""z"\"" {f=1}
    f && /file/ {gsub(/.*file[ \t]*"|".*/,""); print; exit}' "$LOC" 2>/dev/null)
  [ -n "$f" ] && [[ "$f" != /* ]] && f="/var/cache/bind/$f"           # chemin relatif -> repertoire BIND
  echo "$f"
}

# add_rr FICHIER MOTIF LIGNE : ajoute LIGNE au fichier seulement si MOTIF n'y est pas deja (idempotent)
add_rr() { grep -qE "$2" "$1" || printf '%b\n' "$3" >> "$1"; }

# =====================================================================
#                         CONFIGURATION DU MASTER
# =====================================================================
# ensure_zone ZONE FICHIER_PAR_DEFAUT : declare la zone si besoin, cree son fichier, garantit les NS ; resultat dans $ZF
ensure_zone() {
  local z=$1 def=$2
  if ! grep -q "zone \"$z\"" "$LOC"; then                             # zone pas encore declaree
    printf 'zone "%s" IN {\n\ttype master;\n\tfile "%s";\n};\n' "$z" "$def" >> "$LOC"
    echo " + zone $z declaree"
  fi
  ZF=$(zonefile_of "$z")                                              # fichier de zone declare
  [ -z "$ZF" ] && ZF="$def"                                           # sinon fichier par defaut
  if [ ! -f "$ZF" ]; then                                             # le fichier n'existe pas : on le cree
    cat > "$ZF" <<EOF
\$TTL 604800
@	IN	SOA	$M_NAME.$DOMAIN. admin.$DOMAIN. (
		$(date +%Y%m%d)01 ; Serial
		604800 ; Refresh
		86400 ; Retry
		2419200 ; Expire
		604800 ) ; Negative Cache TTL
@	IN	NS	$M_NAME.$DOMAIN.
@	IN	NS	$S_NAME.$DOMAIN.
EOF
    echo " + fichier $ZF cree"
  fi
  [ -n "$(tail -c1 "$ZF")" ] && echo >> "$ZF"                         # force un saut de ligne final
  add_rr "$ZF" "NS[[:space:]]+$M_NAME\\.$DOMAIN\\." "@\tIN\tNS\t$M_NAME.$DOMAIN."   # serveur de noms Master
  add_rr "$ZF" "NS[[:space:]]+$S_NAME\\.$DOMAIN\\." "@\tIN\tNS\t$S_NAME.$DOMAIN."   # serveur de noms Slave
}

# cfg_master : configuration complete du Master
cfg_master() {
  title "CONFIGURATION DU MASTER ($M_NAME)"
  check_expected_ips "$M_OCT" "$M_NAT" || return                      # affiche les interfaces, controle les IP
  set_hostname "$M_NAME"                                              # nom de la machine
  info "Installation de bind9..."
  apt-get update -qq; apt-get install -y -qq bind9 dnsutils >/dev/null || { echo "${R}Installation impossible (Internet ?)${N}"; return; }

  local BK=/root/backup-dns-$(date +%H%M%S); mkdir -p "$BK"           # dossier de sauvegarde horodate
  cp "$OPT" "$LOC" "$BK/" 2>/dev/null; [ -f "$DHCPC" ] && cp "$DHCPC" "$BK/"   # copie des fichiers avant modification
  echo " Sauvegardes dans $BK"

  # Options globales BIND : ecoute, recursion limitee aux LAN, forwarder, replication vers le Slave
  cat > "$OPT" <<EOF
options {
	directory "/var/cache/bind";
	listen-on { any; };
	listen-on-v6 { none; };
	allow-query { any; };
	allow-recursion { $L1.0/24; $L2.0/24; $L3.0/24; $NATNET.0/24; localhost; };
	recursion yes;
	forwarders { $FWD; };
	forward first;
	dnssec-validation no;
	notify yes;
	allow-transfer { $S_LIST};
	also-notify { $S_LIST};
};
EOF
  sed -i '/allow-transfer/d;/also-notify/d' "$LOC"                    # retire les anciennes regles par zone (elles masqueraient les globales)

  ZFILES=()                                                           # liste "zone|fichier" des zones gerees
  ensure_zone "$DOMAIN" "/etc/bind/db.$DOMAIN"; ZFILES+=("$DOMAIN|$ZF")   # zone directe
  add_rr "$ZF" "^$M_NAME[[:space:]]" "$M_NAME\tIN\tA\t$M_NAT"         # A du Master
  add_rr "$ZF" "^$S_NAME[[:space:]]" "$S_NAME\tIN\tA\t$L1.$S_OCT"     # A du Slave
  add_rr "$ZF" "^www[[:space:]]"     "www\tIN\tA\t$M_NAT"             # A de www
  for l in "${LANS[@]}"; do                                           # une zone inverse par LAN
    ensure_zone "$(rev $l)" "/etc/bind/db.$l"; ZFILES+=("$(rev $l)|$ZF")
    add_rr "$ZF" "^$M_OCT[[:space:]]" "$M_OCT\tIN\tPTR\t$M_NAME.$DOMAIN."   # PTR du Master
    add_rr "$ZF" "^$S_OCT[[:space:]]" "$S_OCT\tIN\tPTR\t$S_NAME.$DOMAIN."   # PTR du Slave
  done
  ensure_zone "$(rev $NATNET)" "/etc/bind/db.$NATNET"; ZFILES+=("$(rev $NATNET)|$ZF")   # zone inverse NAT
  add_rr "$ZF" "^${M_NAT##*.}[[:space:]]" "${M_NAT##*.}\tIN\tPTR\t$M_NAME.$DOMAIN."
  add_rr "$ZF" "^${S_NAT##*.}[[:space:]]" "${S_NAT##*.}\tIN\tPTR\t$S_NAME.$DOMAIN."

  echo " Incrementation des serials et controle des zones :"
  local e z f
  for e in "${ZFILES[@]}"; do
    z=${e%%|*}; f=${e#*|}                                             # separe "zone|fichier"
    echo " - $z ($f)"
    bump_serial "$f"                                                  # nouveau serial pour que le Slave replique
    named-checkzone "$z" "$f" >/dev/null 2>&1 && echo "   syntaxe OK" || echo "   ${R}!! erreur : named-checkzone $z $f${N}"
  done

  if ! named-checkconf; then                                          # controle de la configuration globale
    echo "${R}!! named-checkconf en erreur : restauration des sauvegardes${N}"
    cp "$BK/$(basename $OPT)" "$OPT"; cp "$BK/$(basename $LOC)" "$LOC"; return
  fi
  systemctl enable bind9 >/dev/null 2>&1                              # demarrage automatique
  systemctl restart bind9; sleep 2                                    # applique la configuration
  systemctl is-active --quiet bind9 || { echo "${R}bind9 inactif${N}"; journalctl -u bind9 --no-pager | tail -15; return; }
  for e in "${ZFILES[@]}"; do rndc notify "${e%%|*}" >/dev/null 2>&1; done   # previent le Slave de chaque zone
  echo " bind9 actif, NOTIFY envoye au Slave"

  if [ -f "$DHCPC" ] && yn "Mettre a jour le DHCP (domaine $DOMAIN + DNS Master et Slave) ?" "O"; then
    sed -i '/^option domain-name "/d' "$DHCPC"                        # retire l'ancien domaine
    sed -i "1i option domain-name \"$DOMAIN\";" "$DHCPC"              # insere le nouveau en tete de fichier
    for l in "${LANS[@]}"; do                                         # pour chaque sous-reseau
      sed -i "/subnet $l\.0[[:space:]]/,/}/{/option domain-name-servers/d}" "$DHCPC"   # retire l'ancienne ligne DNS
      sed -i "/subnet $l\.0[[:space:]]/a\\  option domain-name-servers $l.$M_OCT, $l.$S_OCT;" "$DHCPC"   # ajoute Master + Slave
    done
    if dhcpd -t -cf "$DHCPC" >/dev/null 2>&1; then                    # syntaxe DHCP valide ?
      systemctl restart isc-dhcp-server && echo " DHCP redemarre"
    else
      echo "${R}!! dhcpd.conf invalide, restauration${N}"; cp "$BK/dhcpd.conf" "$DHCPC"
    fi
  fi
  echo; echo " ${G}Master configure.${N} Lancez maintenant l'option 2 sur le Slave."
  verify_master                                                       # verification automatique
}

# =====================================================================
#                         CONFIGURATION DU SLAVE
# =====================================================================
cfg_slave() {
  title "CONFIGURATION DU SLAVE ($S_NAME)"
  check_expected_ips "$S_OCT" "$S_NAT" || return                      # affiche les interfaces, controle les IP
  set_hostname "$S_NAME"                                              # nom de la machine
  ping -c2 -W2 "$MASTER_IP" >/dev/null 2>&1 || { echo "${R}!! Master $MASTER_IP injoignable. Configurez d'abord le Master.${N}"; return; }
  echo " Master $MASTER_IP joignable"
  info "Installation de bind9..."
  apt-get update -qq; apt-get install -y -qq bind9 dnsutils >/dev/null || { echo "${R}Installation impossible (Internet ?)${N}"; return; }

  ZONES=()                                                            # zones que le Master heberge vraiment
  local z
  for z in "${CAND[@]}"; do
    [ -n "$(dig +short +time=3 +tries=1 @"$MASTER_IP" "$z" SOA 2>/dev/null)" ] && ZONES+=("$z")   # le Master repond pour cette zone
  done
  local EXTRA; EXTRA=$(ask "Zones supplementaires (separees par des espaces, vide = aucune)" "")
  for z in $EXTRA; do ZONES+=("$z"); done                             # zones ajoutees a la main
  [ ${#ZONES[@]} -eq 0 ] && { echo "${R}!! Le Master n'heberge aucune zone. Lancez d'abord l'option 1 sur le Master.${N}"; return; }
  echo " Zones a repliquer : ${ZONES[*]}"

  local BK=/root/backup-dns-$(date +%H%M%S); mkdir -p "$BK"; cp "$OPT" "$LOC" "$BK/" 2>/dev/null   # sauvegardes
  # Options du Slave : meme resolution que le Master, mais aucune replication sortante
  cat > "$OPT" <<EOF
options {
	directory "/var/cache/bind";
	listen-on { any; };
	listen-on-v6 { none; };
	allow-query { any; };
	allow-recursion { $L1.0/24; $L2.0/24; $L3.0/24; $NATNET.0/24; localhost; };
	recursion yes;
	forwarders { $FWD; };
	forward first;
	dnssec-validation no;
};
EOF
  : > "$LOC"                                                          # vide le fichier des zones
  for z in "${ZONES[@]}"; do                                          # declare chaque zone en type slave
    cat >> "$LOC" <<EOF
zone "$z" IN {
	type slave;
	file "slaves/db.$z";
	masters { $MASTER_IP; };
	allow-transfer { none; };
};
EOF
  done
  mkdir -p /var/cache/bind/slaves; chown -R bind:bind /var/cache/bind/slaves   # dossier de copie des zones
  if ! named-checkconf; then                                          # controle de la configuration
    echo "${R}!! Erreur de configuration, restauration${N}"
    cp "$BK/$(basename $OPT)" "$OPT"; cp "$BK/$(basename $LOC)" "$LOC"; return
  fi
  systemctl enable bind9 >/dev/null 2>&1                              # demarrage automatique
  systemctl restart bind9                                             # applique la configuration
  echo -n " Transfert de zones en cours"
  local i okk
  for i in $(seq 1 25); do                                            # attend jusqu'a 25 s les fichiers de zone
    okk=1; for z in "${ZONES[@]}"; do [ -s "/var/cache/bind/slaves/db.$z" ] || okk=0; done
    [ $okk -eq 1 ] && break; echo -n "."; sleep 1
  done; echo
  echo " ${G}Slave configure.${N}"
  verify_slave                                                        # verification automatique
}

# =====================================================================
#                  CONFIGURATION D'UN CLIENT LINUX / IoT
# =====================================================================
cfg_client() {
  title "CONFIGURATION D'UN CLIENT LINUX / IoT (DHCP + DNS)"
  echo "1) Client Linux  ($LINUX_NAME, LAN2 $L2.0/24)"
  echo "2) Client IoT    ($IOT_NAME, LAN3 $L3.0/24)"
  local c; read -rp "Votre choix [1/2] : " c                          # type de client
  local NAME NAT_LAST LANP
  case "$c" in
    1) NAME=$LINUX_NAME; NAT_LAST=30; LANP=$L2;;                      # Linux : LAN2, IP NAT .30
    2) NAME=$IOT_NAME;   NAT_LAST=40; LANP=$L3;;                      # IoT   : LAN3, IP NAT .40
    *) echo "Choix invalide."; return;;
  esac

  title "Interfaces reseau detectees sur cette machine"
  list_interfaces                                                     # tableau : nom, etat, MAC, IP
  echo
  local NAT_IF LAN_IF NAT_IP
  # Propose comme interface NAT celle qui porte deja une adresse 192.168.100.x
  NAT_IF=$(ip -4 -o a | awk -v n="$NATNET." 'index($4,n)==1{print $2; exit}')
  # Propose comme interface LAN celle qui porte deja une adresse d'un des 3 LAN
  LAN_IF=$(ip -4 -o a | awk -v a="$L1." -v b="$L2." -v c="$L3." 'index($4,a)==1||index($4,b)==1||index($4,c)==1{print $2; exit}')
  # A defaut, prend la premiere interface existante (hors lo) pour la NAT, puis une autre pour le LAN
  [ -z "$NAT_IF" ] && NAT_IF=$(ls /sys/class/net | grep -v '^lo$' | head -1)
  [ -z "$LAN_IF" ] && LAN_IF=$(ls /sys/class/net | grep -vE "^(lo|$NAT_IF)$" | head -1)

  NAME=$(ask "Hostname" "$NAME")                                      # nom de la machine
  NAT_IF=$(ask_iface "Interface NAT (administration MobaXterm)" "$NAT_IF")   # refuse un nom inexistant
  while true; do
    LAN_IF=$(ask_iface "Interface LAN (branchee sur le LAN Segment de $LANP.0/24)" "$LAN_IF")
    [ "$LAN_IF" != "$NAT_IF" ] && break                               # NAT et LAN doivent etre differentes
    echo "${R}!! L'interface LAN doit etre differente de l'interface NAT ($NAT_IF).${N}"
    LAN_IF=$(ls /sys/class/net | grep -vE "^(lo|$NAT_IF)$" | head -1)
  done
  NAT_IP=$(ask "IP NAT de ce client" "$NATNET.$NAT_LAST")             # adresse d'administration

  echo
  echo " Recapitulatif :"
  echo "   Hostname : $NAME"
  echo "   NAT      : $NAT_IF = $NAT_IP/24 (statique, SANS passerelle)"
  echo "   LAN      : $LAN_IF en DHCP (reseau attendu $LANP.0/24, passerelle $LANP.$M_OCT)"
  yn "Appliquer cette configuration ?" "O" || return                  # derniere confirmation
  if [ "$(ip -4 -o a show dev "$NAT_IF" 2>/dev/null | awk '{print $4}' | head -1)" != "$NAT_IP/24" ]; then
    echo " ${Y}L'IP NAT change : si vous etes connecte en SSH sur l'ancienne, reconnectez-vous sur $NAT_IP.${N}"
  fi

  set_hostname "$NAME"                                                # hostname + /etc/hosts
  systemctl disable --now bind9 >/dev/null 2>&1                       # un client n'est pas un serveur DNS
  systemctl enable --now systemd-networkd systemd-resolved >/dev/null 2>&1   # services reseau et resolveur
  ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf       # resolv.conf gere par systemd-resolved

  local BN=/root/bak-net-$(date +%H%M%S); mkdir -p "$BN"              # sauvegarde des anciens fichiers reseau
  mv /etc/systemd/network/*.network "$BN"/ 2>/dev/null                # ecarte les anciennes configurations (ex. clone du Slave)
  cat > /etc/systemd/network/10-wan.network <<EOF
# Carte NAT : adresse fixe d'administration, volontairement sans passerelle
[Match]
Name=$NAT_IF

[Network]
Address=$NAT_IP/24
LinkLocalAddressing=no
IPv6AcceptRA=no
EOF
  cat > /etc/systemd/network/30-lan.network <<EOF
# Carte LAN : tout (IP, passerelle, DNS, domaine) vient du DHCP du Master
[Match]
Name=$LAN_IF

[Network]
DHCP=ipv4
IPv6AcceptRA=no

[DHCPv4]
UseDNS=true
UseDomains=true
UseRoutes=true
SendHostname=true
ClientIdentifier=mac
EOF
  echo " Anciens fichiers .network sauvegardes dans $BN"

  if yn "Regenerer le machine-id (obligatoire si cette VM est un clone) ?" "O"; then regen_machine_id; fi

  systemctl restart systemd-resolved                                  # redemarre le resolveur d'abord
  systemctl restart systemd-networkd                                  # puis le reseau (il pousse les DNS au resolveur)
  networkctl reconfigure "$LAN_IF" >/dev/null 2>&1                    # force une nouvelle demande DHCP
  echo -n " Attente du bail DHCP et des DNS"
  local i
  for i in $(seq 1 30); do                                            # attend jusqu'a 30 s : IP puis DNS visibles
    ip -4 -o a show dev "$LAN_IF" 2>/dev/null | grep -q 'inet ' && \
      resolvectl dns "$LAN_IF" 2>/dev/null | grep -q '[0-9]\.[0-9]' && break
    echo -n "."; sleep 1
  done; echo
  ip -4 -o a show dev "$LAN_IF" | grep -q 'inet ' || echo "${R}!! Pas d'adresse DHCP sur $LAN_IF. Verifiez le LAN Segment dans VMware et que le Master tourne.${N}"
  echo " Un redemarrage est conseille pour que tous les services prennent le nouveau nom et machine-id."
  verify_client                                                       # verification automatique
  yn "Redemarrer maintenant ?" "N" && reboot
}

# =====================================================================
#                              VERIFICATIONS
# =====================================================================
verify_master() {
  title "VERIFICATION DU MASTER"
  need_dig                                                            # dig est necessaire aux tests
  echo; list_interfaces; echo                                         # rappel des interfaces
  local l z m s
  eq "Hostname" "$M_NAME" "$(hostnamectl --static)"                   # nom de la machine
  for l in "${LANS[@]}"; do chk "IP $l.$M_OCT presente" "verifier le fichier .network" bash -c "ip -4 -br a | grep -q '$l.$M_OCT/'"; done
  chk "IP NAT $M_NAT presente" "verifier la carte NAT" bash -c "ip -4 -br a | grep -q '$M_NAT/'"
  for s in bind9 isc-dhcp-server nftables; do                         # les 3 services du Master
    chk "Service $s actif" "systemctl status $s --no-pager" systemctl is-active --quiet $s
  done
  eq "Routage IPv4 (ip_forward)" "1" "$(cat /proc/sys/net/ipv4/ip_forward)"   # le Master doit router
  chk "Regle NAT masquerade (nftables)" "verifier /etc/nftables.conf" bash -c "nft list ruleset 2>/dev/null | grep -q masquerade"
  chk "named-checkconf" "corriger $OPT / $LOC" named-checkconf
  chk "bind9 ecoute sur le port 53" "ss -lntu | grep ':53'" bash -c "ss -lntu | grep -q ':53 '"

  echo; echo " --- Zones et replication (Master -> Slave $SLAVE_IP) ---"
  for z in "${CAND[@]}"; do                                           # compare les serials de chaque zone
    m=$(serial_of 127.0.0.1 "$z"); s=$(serial_of "$SLAVE_IP" "$z")
    if [ -z "$m" ]; then ko "Zone $z absente du Master" "relancer l'option 1"
    elif [ -z "$s" ]; then ko "Zone $z : le Slave ne repond pas" "Slave eteint ou non configure (option 2) ; rndc notify $z"
    else eq "Serial $z identique Master/Slave" "$m" "$s"; fi
  done

  echo; echo " --- Resolution ---"
  eq "$M_NAME.$DOMAIN"  "$M_NAT"     "$(dig +short @127.0.0.1 $M_NAME.$DOMAIN)"
  eq "$S_NAME.$DOMAIN"  "$L1.$S_OCT" "$(dig +short @127.0.0.1 $S_NAME.$DOMAIN)"
  eq "www.$DOMAIN"      "$M_NAT"     "$(dig +short @127.0.0.1 www.$DOMAIN)"
  has "PTR de $L1.$S_OCT" "$S_NAME" "$(dig +short -x $L1.$S_OCT @127.0.0.1)"
  has "PTR de $M_NAT"     "$M_NAME" "$(dig +short -x $M_NAT @127.0.0.1)"
  [ -n "$(dig +short +time=3 +tries=1 @127.0.0.1 deb.debian.org)" ] && ok "Resolution externe (forwarder $FWD)" || ko "Resolution externe" "verifier le forwarder $FWD et la carte NAT"
  for l in "${LANS[@]}"; do chk "Slave joignable sur $l.$S_OCT" "Slave eteint ou carte mal branchee" ping -c1 -W2 "$l.$S_OCT"; done
  chk "Acces Internet (ping 8.8.8.8)" "verifier la carte NAT" ping -c1 -W3 8.8.8.8

  echo; echo " --- DHCP ---"
  if [ -f "$DHCPC" ]; then
    chk "dhcpd.conf valide" "dhcpd -t -cf $DHCPC" dhcpd -t -cf "$DHCPC"
    has "Domaine distribue : $DOMAIN" "option domain-name \"$DOMAIN\"" "$(cat $DHCPC)"
    for l in "${LANS[@]}"; do
      has "DNS distribues sur $l.0/24 (.$M_OCT et .$S_OCT)" "option domain-name-servers $l\\.$M_OCT, $l\\.$S_OCT" "$(cat $DHCPC)"
    done
    # Liste des baux ACTIFS (IP + nom du client) lue dans dhcpd.leases
    local act; act=$(awk '/^lease/{ip=$2;h="";st=""} /client-hostname/{h=$2;gsub(/[";]/,"",h)} /binding state/{st=$3;gsub(/;/,"",st)} /^}/{if(ip!=""){if(st=="active")a[ip]=h; else delete a[ip]} ip=""} END{for(i in a)print i" "a[i]}' /var/lib/dhcp/dhcpd.leases 2>/dev/null | sort)
    echo " Baux actifs :"; echo "$act" | sed 's/^/     /'
    has "Bail actif : $LINUX_NAME" "$LINUX_NAME" "$act"
    has "Bail actif : $IOT_NAME"   "$IOT_NAME"   "$act"
    has "Bail actif : $WIN_NAME"   "$WIN_NAME"   "$act"
  else
    info "Pas de $DHCPC : DHCP non verifie"
  fi
  echo; info "machine-id du Master : $(cat /etc/machine-id)  (doit etre different de celui du Slave et des clients)"
  summary
}

verify_slave() {
  title "VERIFICATION DU SLAVE"
  need_dig
  echo; list_interfaces; echo                                         # rappel des interfaces
  local l z m s
  eq "Hostname" "$S_NAME" "$(hostnamectl --static)"
  for l in "${LANS[@]}"; do chk "IP $l.$S_OCT presente" "verifier le fichier .network" bash -c "ip -4 -br a | grep -q '$l.$S_OCT/'"; done
  chk "IP NAT $S_NAT presente" "verifier la carte NAT" bash -c "ip -4 -br a | grep -q '$S_NAT/'"
  chk "Service bind9 actif" "journalctl -u bind9 --no-pager | tail -20" systemctl is-active --quiet bind9
  chk "named-checkconf" "corriger $OPT / $LOC" named-checkconf
  for l in "${LANS[@]}"; do chk "Master joignable sur $l.$M_OCT" "Master eteint ou carte mal branchee" ping -c1 -W2 "$l.$M_OCT"; done

  echo; echo " --- Zones repliquees ---"
  for z in "${CAND[@]}"; do
    chk "Fichier slaves/db.$z present" "transfert refuse ? voir journalctl -u bind9" test -s "/var/cache/bind/slaves/db.$z"
    m=$(serial_of "$MASTER_IP" "$z"); s=$(serial_of 127.0.0.1 "$z")   # serial chez le Master puis chez le Slave
    if [ -z "$s" ]; then ko "Zone $z non servie par le Slave" "attendre quelques secondes ou : rndc retransfer $z"
    else eq "Serial $z Master/Slave" "$m" "$s"; fi
  done
  chk "Transfert AXFR autorise Master -> Slave" "verifier allow-transfer et le pare-feu sur le Master" bash -c "dig +time=5 +tries=1 @$MASTER_IP $DOMAIN AXFR | grep -q 'XFR size'"
  chk "Le Slave refuse de transferer la zone a un tiers" "mettre allow-transfer { none; };" bash -c "! dig +time=5 +tries=1 @127.0.0.1 $DOMAIN AXFR | grep -q 'XFR size'"

  echo; echo " --- Le Slave repond sur chacune de ses adresses ---"
  for l in "${LANS[@]}"; do
    eq "www.$DOMAIN via $l.$S_OCT" "$M_NAT" "$(dig +short +time=3 +tries=1 @$l.$S_OCT www.$DOMAIN)"
  done
  eq "www.$DOMAIN via $S_NAT" "$M_NAT" "$(dig +short +time=3 +tries=1 @$S_NAT www.$DOMAIN)"
  has "PTR de $L1.$M_OCT" "$M_NAME" "$(dig +short -x $L1.$M_OCT @127.0.0.1)"
  [ -n "$(dig +short +time=3 +tries=1 @127.0.0.1 deb.debian.org)" ] && ok "Resolution externe" || ko "Resolution externe" "verifier le forwarder $FWD"
  echo; info "machine-id du Slave : $(cat /etc/machine-id)  (doit etre different de celui du Master)"
  summary
}

verify_client() {
  title "VERIFICATION DU CLIENT LINUX / IoT"
  need_dig
  echo; list_interfaces; echo; ip route; echo                         # interfaces et table de routage
  local gw nd prefix dns dom t
  gw=$(ip -4 route show default | awk '{print $3; exit}')            # passerelle par defaut
  nd=$(ip -4 route show default | wc -l)                              # nombre de routes par defaut
  eq "Nombre de routes par defaut" "1" "$nd"                          # il ne doit y en avoir qu'une (via le Master)
  [ -z "$gw" ] && { ko "Aucune passerelle" "pas de bail DHCP : verifier le LAN Segment dans VMware"; summary; return; }
  prefix=${gw%.*}                                                     # reseau du client deduit de la passerelle
  has "Reseau LAN reconnu ($prefix)" "^($L1|$L2|$L3)$" "$prefix"
  eq "Passerelle (Master)" "$prefix.$M_OCT" "$gw"
  chk "Adresse LAN obtenue en DHCP" "ip -4 a | grep dynamic" bash -c "ip -4 -o a | grep -q dynamic"
  chk "Pas de route par defaut via le NAT ($NATNET.x)" "supprimer Gateway= dans 10-wan.network" bash -c "! ip -4 route show default | grep -q '$NATNET\.'"
  for t in $(seq 1 15); do                                            # attend que resolvectl affiche les DNS du bail
    dns=$(resolvectl dns 2>/dev/null)
    echo "$dns" | grep -q "$prefix\.$M_OCT" && break
    [ $t -eq 1 ] && info "Attente des DNS du bail DHCP (resolvectl)..."
    sleep 1
  done
  dom=$(resolvectl domain 2>/dev/null)                                # domaines de recherche
  has "DNS 1 = Master $prefix.$M_OCT" "$prefix\\.$M_OCT" "$dns"
  has "DNS 2 = Slave  $prefix.$S_OCT" "$prefix\\.$S_OCT" "$dns"
  has "Suffixe de recherche $DOMAIN" "$DOMAIN" "$dom"
  chk "/etc/hosts contient le hostname ($(hostname))" "relancer l'option 3" bash -c "grep -q '^127.0.1.1.*$(hostname)' /etc/hosts"
  chk "bind9 n'est pas actif sur un client" "systemctl disable --now bind9" bash -c "! systemctl is-active --quiet bind9"

  echo; echo " --- Resolution ---"
  eq "$M_NAME.$DOMAIN"        "$M_NAT"     "$(dig +short +time=3 +tries=1 $M_NAME.$DOMAIN)"
  eq "$S_NAME.$DOMAIN"        "$L1.$S_OCT" "$(dig +short +time=3 +tries=1 $S_NAME.$DOMAIN)"
  has "Inverse de $L1.$S_OCT" "$S_NAME"    "$(dig +short +time=3 +tries=1 -x $L1.$S_OCT)"
  eq "www via le Master ($prefix.$M_OCT)" "$M_NAT" "$(dig +short +time=3 +tries=1 @$prefix.$M_OCT www.$DOMAIN)"
  eq "www via le Slave  ($prefix.$S_OCT)" "$M_NAT" "$(dig +short +time=3 +tries=1 @$prefix.$S_OCT www.$DOMAIN)"
  chk "Ping du Master $gw" "verifier le LAN Segment" ping -c2 -W2 "$gw"
  chk "Ping du Slave $prefix.$S_OCT" "Slave eteint ou sans carte sur ce LAN" ping -c2 -W2 "$prefix.$S_OCT"
  chk "Resolution + ping Internet (deb.debian.org)" "verifier le NAT du Master" ping -c2 -W3 deb.debian.org
  echo; info "Hostname : $(hostnamectl --static) | machine-id : $(cat /etc/machine-id)"
  info "Test de panne : option 8 sur le Master, puis ici : resolvectl flush-caches ; dig www.$DOMAIN +short"
  summary
}

# =====================================================================
#             TEST DE REPLICATION AUTOMATIQUE (a lancer sur le Master)
# =====================================================================
test_repl() {
  title "TEST DE REPLICATION AUTOMATIQUE (a lancer sur le Master)"
  need_dig
  grep -q "type master" "$LOC" 2>/dev/null || { echo "${R}Cette machine n'est pas le Master.${N}"; return; }
  local rr ipx f got m s
  rr=$(ask "Nom de l'enregistrement de test" "ftp")                   # nom a creer (ftp.ingSALI-infra.lan)
  ipx=$(ask "Adresse IP associee" "$L1.50")                           # adresse de test
  f=$(zonefile_of "$DOMAIN")                                          # fichier de la zone directe
  [ -f "$f" ] || { echo "${R}Fichier de zone $DOMAIN introuvable.${N}"; return; }
  [ -n "$(tail -c1 "$f")" ] && echo >> "$f"                           # saut de ligne final
  add_rr "$f" "^$rr[[:space:]]" "$rr\tIN\tA\t$ipx"                    # ajoute l'enregistrement
  bump_serial "$f"                                                    # incremente le serial (obligatoire)
  named-checkzone "$DOMAIN" "$f" >/dev/null 2>&1 || { echo "${R}Erreur de syntaxe dans $f${N}"; return; }
  rndc reload "$DOMAIN" >/dev/null 2>&1; rndc notify "$DOMAIN" >/dev/null 2>&1   # recharge la zone et previent le Slave
  echo " Enregistrement $rr.$DOMAIN -> $ipx ajoute, NOTIFY envoye. Attente 5 s..."
  sleep 5
  got=$(dig +short +time=3 +tries=1 @"$SLAVE_IP" "$rr.$DOMAIN")       # le Slave connait-il le nouvel enregistrement ?
  eq "Le Slave connait $rr.$DOMAIN" "$ipx" "$got"
  m=$(serial_of 127.0.0.1 "$DOMAIN"); s=$(serial_of "$SLAVE_IP" "$DOMAIN")
  eq "Serial Master/Slave" "$m" "$s"
  summary
  echo " Sur le Slave : dig @127.0.0.1 $rr.$DOMAIN +short   (attendu : $ipx)"
  echo " Sur Windows  : nslookup $rr.$DOMAIN $SLAVE_IP"
  if yn "Supprimer l'enregistrement de test ?" "N"; then
    sed -i "/^$rr[[:space:]]/d" "$f"; bump_serial "$f"                # retire la ligne et incremente le serial
    rndc reload "$DOMAIN" >/dev/null 2>&1; rndc notify "$DOMAIN" >/dev/null 2>&1; echo " Supprime."
  fi
}

# =====================================================================
#                TEST DE PANNE DU MASTER (a lancer sur le Master)
# =====================================================================
test_panne() {
  title "TEST DE PANNE : arret de bind9 sur le Master"
  need_dig
  systemctl is-active --quiet bind9 || { echo "bind9 n'est pas actif ici (cette machine est-elle le Master ?)"; return; }
  yn "bind9 va etre arrete puis relance. Continuer ?" "O" || return
  trap 'systemctl start bind9; echo; echo "bind9 relance."; trap - INT; return' INT   # Ctrl+C relance bind9 par securite
  systemctl stop bind9; sleep 1                                       # simule la panne
  if dig +short +time=2 +tries=1 @127.0.0.1 www.$DOMAIN | grep -q .; then ko "Le DNS du Master repond encore" "bind9 n'est pas arrete"
  else ok "DNS du Master arrete (panne simulee)"; fi
  eq "Le Slave repond seul : www.$DOMAIN" "$M_NAT" "$(dig +short +time=3 +tries=1 @$SLAVE_IP www.$DOMAIN)"
  summary
  cat <<EOF

 ${Y}MAINTENANT, depuis les clients (DNS du Master arrete) :${N}
   Client Linux / IoT :  resolvectl flush-caches
                         dig www.$DOMAIN +short        -> $M_NAT (via le Slave, petit delai)
   Windows (cmd)      :  ipconfig /flushdns
                         nslookup www.$DOMAIN $SLAVE_IP -> repond (Server: $S_NAME)
                         ping www.$DOMAIN               -> le nom doit se resoudre
   (nslookup sans serveur precise n'essaie que le 1er DNS : des timeouts sont normaux.)

EOF
  read -rp " Faites vos captures, puis appuyez sur Entree pour RELANCER bind9... " _
  systemctl start bind9; sleep 2                                      # fin de la panne
  trap - INT
  systemctl is-active --quiet bind9 && ok "bind9 relance" || ko "bind9 ne redemarre pas" "journalctl -u bind9"
  eq "Le Master repond de nouveau : www.$DOMAIN" "$M_NAT" "$(dig +short +time=3 +tries=1 @127.0.0.1 www.$DOMAIN)"
  summary
}

# =====================================================================
#          GUIDE DE VERIFICATION WINDOWS (a executer sous Windows)
# =====================================================================
guide_windows() {
  local out=/root/guide-windows-verification.txt                      # fichier ou le guide est enregistre
  cat > "$out" <<EOF
=====================================================================
 GUIDE DE VERIFICATION - CLIENT WINDOWS ($WIN_NAME)  domaine $DOMAIN
 A executer dans une invite de commandes (cmd) ouverte en
 ADMINISTRATEUR sur la VM Windows, apres la configuration du Master
 et du Slave. Ces commandes ne s'executent PAS sous Linux.
=====================================================================

ETAPE 1 - DHCP : adresse, passerelle, DNS, suffixe
  ipconfig /release
  ipconfig /renew
  ipconfig /all
  Attendu :
    IPv4 Address ............ $L1.x (ex. $L1.11), masque 255.255.255.0
    Default Gateway ......... $L1.$M_OCT
    DHCP Server ............. $L1.$M_OCT
    DNS Servers ............. $L1.$M_OCT  puis  $L1.$S_OCT
    Connection-specific DNS Suffix / Search List : $DOMAIN
    Host Name ............... $WIN_NAME
  CAPTURE 1 : ipconfig /all

ETAPE 2 - DNS direct via le Master (serveur par defaut)
  nslookup $M_NAME
  nslookup $S_NAME.$DOMAIN
  nslookup www.$DOMAIN
  Attendu :
    Server: $M_NAME.$DOMAIN / Address: $L1.$M_OCT
    $M_NAME -> $M_NAT      $S_NAME -> $L1.$S_OCT      www -> $M_NAT
  CAPTURE 2

ETAPE 3 - DNS inverse
  nslookup $L1.$S_OCT
  nslookup $L1.$M_OCT
  Attendu : Name: $S_NAME.$DOMAIN  puis  Name: $M_NAME.$DOMAIN
  CAPTURE 3

ETAPE 4 - Le Slave repond aux clients (serveur precise a la main)
  nslookup www.$DOMAIN $SLAVE_IP
  nslookup $M_NAME $SLAVE_IP
  Attendu : Server: $S_NAME.$DOMAIN / Address: $SLAVE_IP
            et les memes reponses que le Master.
  CAPTURE 4 : preuve que le Slave sert les clients

ETAPE 5 - Connectivite, passerelle et Internet via le Master
  ping $L1.$M_OCT
  ping $L1.$S_OCT
  ping deb.debian.org
  tracert -d 8.8.8.8
  Attendu : ping 0% de perte (TTL 64) ; Internet resolu (TTL 127) ;
            tracert : saut 1 = $L1.$M_OCT, saut 2 = $FWD, puis des
            "Request timed out" (normal avec le NAT VMware).
  CAPTURE 5

ETAPE 6 - Replication automatique (apres l'option 7 sur le Master)
  nslookup ftp.$DOMAIN $SLAVE_IP
  Attendu : l'adresse choisie pour le test (ex. $L1.50).
  CAPTURE 6

ETAPE 7 - TEST DE PANNE (apres l'option 8 : bind9 arrete sur le Master)
  ipconfig /flushdns
  nslookup www.$DOMAIN $SLAVE_IP
  ping www.$DOMAIN
  nslookup www.$DOMAIN
  Attendu :
    - nslookup ... $SLAVE_IP : repond (Server: $S_NAME) -> redondance OK
    - ping www.$DOMAIN : le nom est resolu en $M_NAT apres un court delai
      (le resolveur Windows bascule sur le 2e DNS)
    - le dernier nslookup SANS serveur peut afficher des timeouts :
      nslookup n'interroge que le 1er DNS, ce n'est pas une panne de la HA.
  CAPTURE 7 (a faire avant de relancer bind9 sur le Master)
  Puis, apres relance du Master : ipconfig /flushdns  et  nslookup www.$DOMAIN
  (doit repondre de nouveau via $L1.$M_OCT)

ETAPE 8 - (optionnel) Renommer la machine Windows
  wmic computersystem where name="%computername%" call rename name="$WIN_NAME"
  shutdown /r /t 0
  (Windows 10/11, PowerShell admin : Rename-Computer -NewName "$WIN_NAME" -Restart
   et Resolve-DnsName www.$DOMAIN -Server $SLAVE_IP)

CHECKLIST DES CAPTURES POUR LE COMPTE RENDU
  [ ] 1 ipconfig /all (IP, passerelle, 2 DNS, suffixe $DOMAIN)
  [ ] 2 nslookup directs   [ ] 3 nslookup inverses
  [ ] 4 nslookup vers le Slave   [ ] 5 ping + tracert
  [ ] 6 replication (ftp)  [ ] 7 test de panne Master arrete
EOF
  title "GUIDE DE VERIFICATION WINDOWS"
  cat "$out"                                                          # affiche le guide a l'ecran
  echo
  echo " Guide enregistre dans : $out  (copiez-le avec MobaXterm : panneau SFTP a gauche)"
}

# =====================================================================
#                                 MENU
# =====================================================================
# banner : affiche le menu principal
banner() {
  echo
  echo "${B}==============================================================${N}"
  echo "${B}   LABO $DOMAIN : DNS Maitre/Esclave + DHCP + clients${N}"
  echo "${B}==============================================================${N}"
  cat <<EOF
  CONFIGURATION                         VERIFICATION
   1) Configurer le MASTER ($M_NAME)     4) Verifier le MASTER
   2) Configurer le SLAVE  ($S_NAME)     5) Verifier le SLAVE
   3) Configurer un CLIENT Linux/IoT     6) Verifier un CLIENT Linux/IoT

  TESTS                                 OUTILS
   7) Replication auto (Master)          9) Guide de verification Windows
   8) Test de panne du Master (Master)  10) Regenerer le machine-id
                                        11) Lister les interfaces reseau
                                         0) Quitter
EOF
}

load_params                                                           # charge les parametres de la topologie
while true; do                                                        # boucle du menu jusqu'a "0"
  banner
  read -rp "Votre choix : " CH
  case "$CH" in
    1) cfg_master;;                                                   # configuration du Master
    2) cfg_slave;;                                                    # configuration du Slave
    3) cfg_client;;                                                   # configuration d'un client Linux / IoT
    4) verify_master;;                                                # verification du Master
    5) verify_slave;;                                                 # verification du Slave
    6) verify_client;;                                                # verification d'un client
    7) test_repl;;                                                    # test de replication automatique
    8) test_panne;;                                                   # test de panne du Master
    9) guide_windows;;                                                # guide des commandes Windows
    10) regen_machine_id; echo " Redemarrez la machine pour appliquer.";;   # nouveau machine-id
    11) title "Interfaces reseau"; list_interfaces;;                  # liste seule des interfaces
    0) echo "Au revoir."; exit 0;;                                    # quitter
    *) echo "Choix invalide.";;
  esac
  echo; read -rp "Entree pour revenir au menu..." _
done
