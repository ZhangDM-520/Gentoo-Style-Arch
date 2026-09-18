# Legacy texlive-texmf split loop — the equivalence oracle for
# tests/texlive-split.sh. This is the implementation that shipped before
# 2026-09-18: it rescans tlpkg/texlive.tlpdb (18.7 MB) for every collection and
# every package, and moves each file with its own `mkdir -p` + `mv`.
#
# The fixture runs this and the live implementation from
# packages/git/texlive-texmf/PKGBUILD over the same synthetic tree and requires
# identical results, so a rewrite of that loop cannot silently change what the
# packages contain. Do not "fix" anything here — it is a frozen record, and its
# inefficiency is the point.
#
# Contract for the caller: cwd is the synthetic tree, `_collections` is set, and
# the files prepare() copies to the top level (fmtutil.cnf, updmap.cfg,
# language.{dat,dat.lua,def}) already exist there.

  for _coll in ${_collections[@]}; do
    echo -ne "splitting collection ${_coll}"
    # extract description
    _desc=`sed -e "0,/^name collection-${_coll}$/d;/^$/Q" tlpkg/texlive.tlpdb | sed -ne 's|^shortdesc ||p'`
    echo $_desc > pkgdesc-$_coll
    # extract depends
    _pkgs=`sed -e "0,/^name collection-${_coll}$/d;/^$/Q" tlpkg/texlive.tlpdb | sed -ne 's|^depend ||p'`
    _prog=0
    _total=`echo $_pkgs | wc -w`
    for _pkg in $_pkgs; do
      _prog=$(($_prog+1))
      echo -ne "\rsplitting collection ${_coll} ($_prog/$_total)"
      # collection depends are added as dependencies
      if [[ $_pkg == collection-* ]]; then
        echo ${_pkg/collection-/texlive-} >> depends-$_coll
      else
        echo $_pkg >> packages-$_coll
        # move files to the corresponding subdir
        _split=`sed -e "0,/^name ${_pkg}$/d;/^$/Q" tlpkg/texlive.tlpdb`
        _files=`echo "$_split" | sed -e "0,/^runfiles/d;/^[a-z]/Q" | grep texmf-dist` || true
        for _file in $_files; do
          # some modules include docs in runfiles
          [[ $_file == texmf-dist/doc/* ]] && continue
          mkdir -p texlive-$_coll/$(dirname $_file)
          mv $_file texlive-$_coll/$(dirname $_file)
        done
        # extract formats
        _fmts=`echo "$_split" | grep "execute AddFormat"` || true
        if [[ ! -z "$_fmts" ]]; then
          echo "$_fmts" | while read -r _fmt; do
            _name=`echo $_fmt | sed 's|.* name=\(\S*\).*|\1|'`
            _engine=`echo $_fmt | sed 's|.* engine=\(\S*\).*|\1|'`
            grep -E "(^| )$_name $_engine" fmtutil.cnf >> $_coll.fmts
          done
        fi
        # extract maps
        _maps=`echo "$_split" | grep -E "execute add(Kanji|Mixed|)Map"` || true
        if [[ ! -z "$_maps" ]]; then
          echo "$_maps" | while read -r _map; do
            grep "${_map/execute add/}" updmap.cfg >> $_coll.maps
          done
        fi
        # extract hyphen rules
        _langs=`echo "$_split" | grep "execute AddHyphen"` || true
        if [[ ! -z "$_langs" ]]; then
          sed -e "0,/from ${_pkg}:/d;/\%/Q" language.dat >> $_coll.dat
          sed -re "0,/from ${_pkg}:/d;/(^--|^})/Q" language.dat.lua >> $_coll.dat.lua
          sed -e "0,/from ${_pkg}:/d;/\%/Q" language.def >> $_coll.def
        fi
        # extract linked scripts
        if [[ ${_pkg} != psutils && "$_split" == *${_pkg}.ARCH* ]]; then
          _links=`sed -e "0,/^name ${_pkg}.x86_64-linux$/d;/^$/Q" tlpkg/texlive.tlpdb | grep "bin/x86_64-linux" | sed -e 's|bin/x86_64-linux||g'`
          for _link in $_links; do
            if [[ $(readlink -m x86_64-linux/$_link) == */scripts/* ]]; then
              mkdir -p ${_coll}-bin
              cp -P x86_64-linux/$_link ${_coll}-bin
              ln -sfn "$(readlink ${_coll}-bin/$_link | sed 's|..\/..|..\/share|')" ${_coll}-bin/$_link
            fi
          done
        fi
      fi
    done
    echo
  done
