#!/bin/sh
# Bootstraps a from-scratch OpenLDAP install from tests/server/openldap
# (plus the extra files in this directory that fill gaps in those
# fixtures - see 00-au.ldif and 00-base-seed.ldif) and then execs slapd.
#
# Only the very first step (loading 00-base-seed.ldif, which creates
# cn=config itself) has to happen offline via slapadd - there's no server
# to bind to yet. Everything after that runs against a temporary,
# ldapi-only slapd instance, exactly like a human operator would run it by
# hand, which lets us use plain ldapadd/ldapmodify throughout.
set -eu

CONF=/etc/openldap/slapd.d
DATA=/var/lib/openldap
FIXTURES=/fixtures/tests/server/openldap
EXTRA=/fixtures/docker/openldap

# Both directories used to be created for free as volume mount points;
# now that nothing mounts over them, they need to be created explicitly.
# The compiled-in default socket for a bare "ldapi:///" is
# /var/lib/openldap/run/ldapi.
mkdir -p "$CONF" "$DATA/run"
chown ldap:ldap "$DATA/run"

if [ -z "$(ls -A "$CONF" 2>/dev/null)" ]; then
	echo "==> First start: bootstrapping cn=config"

	slapadd -n 0 -F "$CONF" -l "$EXTRA/00-base-seed.ldif"
	chown -R ldap:ldap "$CONF" "$DATA"

	# slapd forks internally when dropping privileges via -u/-g, so the
	# backgrounded shell job's $! isn't the real slapd PID - stop it by
	# name instead.
	slapd -h "ldapi:///" -u ldap -g ldap &
	trap 'pkill -x slapd 2>/dev/null || true' EXIT
	until ldapsearch -Y EXTERNAL -H ldapi:/// -b "" -s base >/dev/null 2>&1; do sleep 0.1; done

	ldap_add() {
		ldapadd -Y EXTERNAL -Q -H ldapi:/// -f "$1"
	}
	ldap_add_or_modify() {
		if grep -qi '^changetype:' "$1"; then
			ldapmodify -Y EXTERNAL -Q -H ldapi:/// -f "$1"
		else
			ldap_add "$1"
		fi
	}

	echo "==> Custom schema"
	for f in "$FIXTURES"/schema/add/*.ldif; do
		ldap_add "$f"
	done
	ldap_add "$EXTRA/00-samba-schema.ldif"

	# Each mdb backend needs its own, pre-existing data directory - the
	# fixtures hardcode the same olcDbDirectory in every bases/*.ldif file,
	# which can't work as-is since backends can't share a directory.
	echo "==> Backend databases"
	prepare_base() {
		src=$1
		name=$(basename "$src" .ldif)
		dbdir="$DATA/data/$name"
		mkdir -p "$dbdir"
		chown -R ldap:ldap "$dbdir"
		# root via ldapi only gets automatic unlimited access on cn=config
		# itself, not on the databases cn=config describes - none of the
		# fixture ACLs grant EXTERNAL write access, so without this,
		# loading data below fails with "no write access to parent".
		sed "s|olcDbDirectory: /var/lib/openldap/data|olcDbDirectory: $dbdir|" "$src" | awk '
			/^olcAccess:/ && !done {
				print "olcAccess: to * by dn.exact=\"gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth\" manage by * break"
				done=1
			}
			{ print }
		' | ldapadd -Y EXTERNAL -Q -H ldapi:///
	}
	prepare_base "$EXTRA/00-au.ldif"
	for f in "$FIXTURES"/bases/*.ldif; do
		prepare_base "$f"
	done

	# tests/server/openldap/schema/modify/*.ldif was written assuming two
	# databases exist ahead of the fixtures' own 5 (bases/21..25 land at
	# {3}-{7}, and the 40-*.ldif overlays target {4}mdb specifically). Our
	# from-scratch cn=config only has our synthesized c=AU ahead of them
	# (bases/21..25 land at {2}-{6}), one lower across the board, so we
	# shift every {N} reference down by one on copy.
	echo "==> Config/overlay modifications"
	# 40-dynlist-options.ldif adds a dynlist overlay, but no fixture file
	# loads the dynlist module itself (unlike memberof/ppolicy/sssvlv,
	# which do have their own 00-*.ldif module loads) - load it here first.
	ldapmodify -Y EXTERNAL -Q -H ldapi:/// <<-EOF
		dn: cn=z-module{0},cn=config
		changetype: modify
		add: olcModuleLoad
		olcModuleLoad: dynlist.so
	EOF
	for f in "$FIXTURES"/schema/modify/*.ldif; do
		name=$(basename "$f")
		# Two passes through distinct placeholder tokens, not one chained
		# sed: shifting {4}->{3} then {3}->{2} in the same pass would
		# re-match and cascade the just-shifted value down again.
		sed -e 's/{3}mdb/{_3}mdb/g' -e 's/{4}mdb/{_4}mdb/g' -e 's/{5}mdb/{_5}mdb/g' \
			-e 's/{6}mdb/{_6}mdb/g' -e 's/{7}mdb/{_7}mdb/g' \
			-e 's/{_3}mdb/{2}mdb/g' -e 's/{_4}mdb/{3}mdb/g' -e 's/{_5}mdb/{4}mdb/g' \
			-e 's/{_6}mdb/{5}mdb/g' -e 's/{_7}mdb/{6}mdb/g' "$f" > /tmp/modify.ldif
		if [ "$name" = "00-mapsize.ldif" ]; then
			# olcDbMaxSize already has a default value once the database
			# exists (this OpenLDAP build populates it), so "add" collides
			# with it; "replace" achieves the same intent (a bigger limit).
			sed -i 's/^add: olcDbMaxSize/replace: olcDbMaxSize/' /tmp/modify.ldif
		fi
		ldap_add_or_modify /tmp/modify.ldif
	done
	rm -f /tmp/modify.ldif

	# Explicit order (not a glob sort) so each suffix's root entry loads
	# before its children, e.g. dc=Test (07-test.ldif) before
	# cn=user,dc=Test (07-test-01.ldif).
	echo "==> Data"
	for name in \
		01-au.ldif \
		03-example.com.ldif \
		04-example_com.ldif \
		04-z_kerberos.ldif \
		04-z_labeleduri.ldif \
		04-z_memberof.ldif \
		04-z_ppolicy.ldif \
		04-z_samba.ldif \
		04-z_usercert.ldif \
		05-flintstones.ldif \
		06-simpsons.ldif \
		07-test.ldif \
		07-test-01.ldif \
		07-test-il8n.ldif \
	; do
		f="$FIXTURES/data/$name"
		if [ "$name" = "04-z_samba.ldif" ]; then
			# entryUUID is a server-managed operational attribute; this
			# fixture was presumably captured via an LDIF export (its
			# header says as much) and re-added with slapadd originally,
			# which allows it. ldapadd over the wire rejects it, and no
			# test asserts on this specific value, so we drop it.
			grep -v '^entryUUID:' "$f" | ldapadd -Y EXTERNAL -Q -H ldapi:///
		else
			ldap_add "$f"
		fi
	done

	pkill -x slapd
	while pgrep -x slapd >/dev/null 2>&1; do sleep 0.1; done
	trap - EXIT

	echo "==> Bootstrap complete"
fi

exec slapd -d 0 -h "ldap:/// ldapi:///" -u ldap -g ldap
