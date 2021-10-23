package require sop 1.7.2	;# For signalsource's domino_ref
package require m2
package require parse_args
package require rl_json
package require gc_class

namespace eval ::flock {
	namespace export *
	namespace ensemble create -prefixes no

	namespace path {
		::parse_args
		::rl_json
	}

	variable base_ds	{}

	if {[llength [info commands ::log]] == 0} {
		# Ensure a basic logging fallback exists
		proc log {lvl msg} {puts stderr $msg}
	}

	gc_class create register { #<<<
		superclass ::sop::signalsource

		variable {*}{
			m2
			type
			id
			conductor_jmid
			type_data
			dominos
			type_data_changes
			onrequest
		}

		constructor args { #<<<
			namespace path [list {*}{
				::parse_args
				::flock
			} [namespace path]]

			parse_args $args {
				-m2			{-default m2}
				-type		{-required}
				-id			{-required}
				-onrequest	{-# {If supplied, this command prefix is invoked to handle requests from conductors}}
			}
			set m2	[uplevel 1 [list namespace which -command $m2]]

			set type_data			{}
			set type_data_changes	{}
			sop::domino new dominos(type_data_changed) -name "type_data_changed"
			$dominos(type_data_changed) attach_output [namespace code {my _send_type_data_changes}]

			[$m2 signal_ref connected] attach_output [namespace code {my _connected_changed}]

			if {[self next] ne ""} next
		}

		#>>>
		destructor { #<<<
			if {[info exists m2] && [info object isa object $m2]} {
				[$m2 signal_ref connected] detach_output [namespace code {my _connected_changed}]
			}
			if {[self next] ne ""} next
		}

		#>>>
		method _connected_changed newstate { #<<<
			set svc	[list flock $type $id]
			if {$newstate} {
				log debug "flock registration for type ($type) id ($id) registering svc ($svc) because m2 is connected"
				$m2 handle_svc $svc [namespace code {my _handle_flock}]
			} else {
				$m2 handle_svc $svc {}
			}
		}

		#>>>
		method _handle_flock {seq data} { #<<<
			try {
				set rest	[lassign $data op]

				switch -exact -- $op {
					conductor {
						if {![info exists conductor_jmid]} {
							set conductor_jmid	[$m2 unique_id]
							$m2 chans register_chan $conductor_jmid [namespace code {my _conductor_chan_cb}]
						}
						$m2 pr_jm $conductor_jmid $seq [list main $type_data]
						$m2 ack $seq "connected"
					}

					default {
						throw nack "Invalid op: \"$op\""
					}
				}
			} trap nack errmsg {
				log notice "Nack flock: $errmsg"
				$m2 nack $seq $errmsg
			} on error {errmsg options} {
				log error "Unhandled error in _handle_flock: [dict get $options -errorinfo]"
				$m2 nack $seq "Internal error"
			} finally {
				if {![$m2 answered $seq]} {
					$m2 nack $seq "Not answered"
				}
			}
		}

		#>>>
		method _conductor_chan_cb {op rest} { #<<<
			switch -exact -- $op {
				cancelled {
					if {[info exists conductor_jmid]} {
						unset conductor_jmid
					}
				}

				req {
					lassign $rest seq prev_seq data
					coroutine coro_onrequest_$seq apply [list \
						{m2 seq prev_seq onrequest data} {
							try {
								if {![info exists onrequest]} {
									throw nack "No requests allowed on this channel"
								}

								log debug "Dispatching request [list {*}$onrequest {*}$data]"
								uplevel #0 [list {*}$onrequest {*}$data] 
							} on ok {res options} {
								$m2 ack $seq [list $res $options]
							} trap nack errmsg {
								$m2 nack $seq $errmsg
							} on error {errmsg options} {
								log error "Unhandled error serving request: [dict get $options -errorinfo]"
								$m2 ack $seq [list $errmsg $options]
							} finally {
								if {![$m2 answered $seq]} {
									$m2 nack $seq "Not answered"
								}
							}
						} [namespace current] \
					] $m2 $seq $prev_seq $onrequest $data
				}
			}
		}

		#>>>
		method set_type_data {field value} { #<<<
			dict set type_data $field $value
			lappend type_data_changes + $field $value
			$dominos(type_data_changed) tip
		}

		#>>>
		method unset_type_data field { #<<<
			if {![dict exists $type_data $field]} return
			dict unset type_data $field
			lappend type_data_changes - $field {}
			$dominos(type_data_changed) tip
		}

		#>>>
		method _send_type_data_changes {} { #<<<
			if {[info exists conductor_jmid]} {
				$m2 jm $conductor_jmid $type_data_changes
			}
		}

		#>>>
	}

	#>>>
	proc list_members args { #<<<
		parse_args $args {
			-m2		{-default m2}
			-type	{-# {If set, list only the registered members of this type}}
		}

		$m2 waitfor connected 1000

		set res	{{}}

		if {[info exists type]} {
			# If a specific type was requested, ensure that the result has that
			# type, so that the callers don't need to test for that key
			json set res $type {[]}
		}

		foreach svc [$m2 all_svcs] {
			if {![string match {flock *} $svc]} continue
			lassign $svc - ftype id
			if {[info exists type] && $type ne $ftype} continue
			if {![json exists $res $ftype]} {
				json set res $ftype {[]}
			}
			json set res $ftype end+1 [json string $id]
		}

		set res
	}

	#>>>
	proc _connected_changed {m2 ds newstate} { #<<<
		variable base_ds
		if {$newstate} {
			# svc_avail_changed will populate
		} else {
			# Lost connection, remove all svcs
			foreach row [$ds get_list {} headers] {
				set svc	[lindex $row 0]
				set jmid	[dict get [$ds get_full_row $svc] jmid]
				if {$jmid ne {}} {
					# Record these so that the _conductor_resp can know to ignore them in the future
					dict set base_ds $m2 orphaned_jmids $jmid 1
				}
				$ds remove_item [$ds get_full_row $svc]
			}
		}
	}

	#>>>
	proc _conductor_resp {m2 ds svc msg} { #<<<
		variable base_ds

		try {
			set item	[$ds get_full_row $svc]
		} trap {DATASOURCE NOT_FOUND} {errmsg options} {
			# We hit this for the jm_can responses to flock members removed from the ds because the svc was revoked, or the m2 connection was lost
			set item	[list svc $svc jmid {}]
		}

		switch -exact -- [dict get $msg type] {
			pr_jm {
				set rest	[lassign [dict get $msg data] chan_name]
				switch -exact -- $chan_name {
					main {
						parse_args $rest {
							initial_type_data	{-required}
						}
						$ds update_item $item [dict merge $item [list jmid [dict get $msg seq] type_data $initial_type_data]]
					}
					default {log error "Unhandled pr_jm from flock connect: $chan_name"}
				}
			}
			jm {
				if {[dict get $msg seq] == [dict get $item jmid]} {
					set type_data	[dict get $item type_data]
					foreach {op field val} [dict get $msg data] {
						switch -exact -- $op {
							+ {dict set type_data $field $val}
							- {dict unset type_data $field}
							default {log error "Unexpected flock jm update op: \"$op\""}
						}
					}
					$ds update_item $item [dict merge $item [list type_data $type_data]]
				} else {
					if {[dict exists $base_ds $m2 orphaned_jmids [dict get $msg seq]]} {
						# Update on orphaned jmid
					} else {
						log error "Unexpected flock channel update: $msg"
					}
				}
			}
			jm_can {
				if {[dict get $msg seq] == [dict get $item jmid]} {
					$ds update_item $item [dict merge $item [list jmid {} state cancelled type_data {}]]
				} else {
					if {[dict exists $base_ds $m2 orphaned_jmids [dict get $msg seq]]} {
						dict unset base_ds $m2 orphaned_jmids [dict get $msg seq]
					} else {
						log error "Unexpected flock channel cancelled: $msg, orphaned: [dict keys [dict get $base_ds $m2 orphaned_jmids]]"
					}
				}
			}
			ack {
				$ds update_item $item [dict merge $item {state connected}]
			}
			nack {
				$ds update_item $item [dict merge $item {state failed}]
				log error "Error connecting to flock member ($svc): [dict get $msg data]"
			}
			default {
				log error "Unexpected response to flock connect ($svc): [dict get $msg type]"
			}
		}
	}

	#>>>
	proc _ds_connect {m2 ds svc} { #<<<
		lassign $svc - type id
		$ds add_item [list svc $svc type $type id $id jmid {} state connecting type_data {}]
		$m2 req $svc conductor [list ::flock::_conductor_resp $m2 $ds $svc]
	}

	#>>>
	proc _ds_disconnect {m2 ds svc} { #<<<
		set item	[$ds get_full_row $svc]
		if {[dict exists $item jmid] && [dict get $item jmid] ne {}} {
			if {[$m2 signal_state connected]} {
				# TODO: save prev_seq to supply here?
				$m2 jm_disconnect [dict get $item jmid]
			}
		}
		$ds remove_item $item
	}

	#>>>
	proc _svc_avail_changed {m2 ds} { #<<<
		set oldids	[lmap row [$ds get_list {}] {lindex $row 0}]
		set newids	[lmap svc [$m2 all_svcs] {if {![string match {flock *} $svc]} continue; set svc}]
		lassign [cflib::intersect3 $oldids $newids] removed - added

		#puts stderr "flock::_svc_avail_changed, added: ($added), removed: ($removed)"
		foreach svc $removed { _ds_disconnect $m2 $ds $svc }
		foreach svc $added   { _ds_connect    $m2 $ds $svc }
	}

	#>>>
	proc _ds_ref m2 { #<<<
		variable base_ds
		if {![dict exists $base_ds $m2]} {
			set ds	[ds::dslist new -headers {svc type id jmid state type_data} -id_column 0]

			[$m2 domino_ref svc_avail_changed] attach_output [list ::flock::_svc_avail_changed $m2 $ds]
			[$m2 signal_ref connected]         attach_output [list ::flock::_connected_changed $m2 $ds]

			foreach svc [$m2 all_svcs] {
				if {![string match {flock *} $svc]} continue
				_ds_connect $m2 $ds $svc
			}

			dict set base_ds $m2 refcount		0
			dict set base_ds $m2 ds				$ds
			dict set base_ds $m2 orphaned_jmids	{}
		}

		dict set base_ds $m2 refcount [expr {[dict get $base_ds $m2 refcount] + 1}]

		dict get $base_ds $m2 ds
	}

	#>>>
	proc _ds_release m2 { #<<<
		variable base_ds
		if {![dict exists $base_ds $m2]} return
		dict set base_ds $m2 refcount [expr {[dict get $base_ds $m2 refcount] - 1}]
		if {[dict get $base_ds $m2 refcount] <= 0} {
			if {[info object isa object [dict get $base_ds $m2 ds]]} {
				set ds	[dict get $base_ds $m2 ds]
				foreach svc [lmap row [$ds get_list {}] {lindex $row 0}] {
					_ds_disconnect $m2 $ds $svc
				}
				[dict get $base_ds $m2 ds] destroy
			}
			dict unset base_ds $m2
		}
	}

	#>>>
	gc_class create members { #<<<
		variable {*}{
			m2
			base_ds
			ds
		}

		constructor args { #<<<
			package require datasource
			package require cflib
			namespace path [list {*}{
				::parse_args
				::rl_json
				::flock
			} [namespace path]]

			parse_args $args {
				-m2		{-default m2}
				-type	{-# {If supplied, limit the visible members to this type}}
			}
			set m2	[uplevel 1 [list namespace which -command $m2]]

			set base_ds	[::flock::_ds_ref $m2]

			if {[info exists type]} {
				ds::datasource_filter create dsfilter \
					-ds $base_ds \
					-filter "\[dict get \$row type\] eq \"[string map [list "\"" "\\\"" "\\" "\\\\"] $type]\""
				set ds	[namespace which -command dsfilter]
			} else {
				set ds	$base_ds
			}

			#$ds register_handler new_item		[namespace code {my _report add}]
			#$ds register_handler change_item	[namespace code {my _report update}]
			#$ds register_handler remove_item	[namespace code {my _report remove}]

			if {[self next] ne ""} next
		}

		#>>>
		destructor { #<<<
			if {[info exists base_ds] && [info object isa object $base_ds]} {
				if {[info exists ds] && $ds ne $base_ds && [info object isa object $ds]} {
					$ds destroy
				}
				::flock::_ds_release $m2
				unset -nocomplain ds base_ds m2
			}
			if {[self next] ne ""} next
		}

		#>>>
		method _report {what args} { # DEBUG <<<
			switch -- $what {
				add {
					parse_args $args {pool -required newid -required newitem -required}
					log debug "ds item added: id: ($newid) $newitem"
				}
				update {
					parse_args $args {pool -required oldid -required olditem -required newitem -required}
					log debug "ds item changed: id: ($oldid) ($olditem) -> ($newitem)"
				}
				remove {
					parse_args $args {pool -required oldid -required olditem -required}
					log debug "ds item removed: id: ($oldid) $olditem"
				}
				default {
					log debug "Unhandled _report case: \"$what\""
				}
			}
		}

		#>>>
		method get id { #<<<
			#log debug "members get [list $id], get_list:\n\t[join [$ds get_list {}] \n\t]"
			$base_ds get $id	;# TODO: change this to $ds once datasource_filter has "get" support
		}

		#>>>
		method get_list {} { #<<<
			$ds get_list {}
		}

		#>>>
		method req_async {id cb args} { #<<<
			set item	[$base_ds get $id]	;# TODO: change this to $ds once datasource_filter has "get" support
			if {![dict exists $item jmid]} {
				log debug "item: ($item), id: ($id)"
				throw [list FLOCK MEMBER_NOT_CONNECTED $id] "Flock member \"$id\" is not connected"
			}
			$m2 rsj_req [dict get $item jmid] $args [list apply {{cb msg} {
				switch -exact -- [dict get $msg type] {
					ack  { {*}$cb [dict get $msg data] }
					nack {
						catch {throw [list FLOCK REQ_NACK] [dict get $msg data]} r o
						{*}$cb [list $r $o]
					}

					default {
						log error "Unhandled flock member req response type: [dict get $msg type]"
					}
				}
			}} $cb]
		}

		#>>>
		method req {id args} { #<<<
			parse_args $args {
				-timeout	{-default 5.0 -# {Maximum time in seconds to wait for a response}}
				args		{-name command}
			}
			if {[info coroutine] ne ""} {
				set waitfor_resp	yield
				set readycb			[list [info coroutine]]
			} else {
				my variable waitresps
				my variable waitresps_seq
				set myseq			[incr waitresps_seq]
				set varname			[namespace which -variable waitresps($myseq)]
				set waitfor_resp	"[list vwait $varname]; [list set $varname]\[[list unset $varname]\]"
				set readycb			[list set $varname]
			}

			#log debug "members req, waitfor_resp: ($waitfor_resp), readycb: ($readycb)"

			set timeout_afterid	[after [expr {int(round($timeout*1000))}] [list $readycb [list \
				"Timeout waiting for response" \
				{-errorcode {FLOCK REQ_TIMEOUT} -code 1 -level 0 -errorinfo {Timeout waiting for response}} \
			]]]

			my req_async $id $readycb {*}$command

			#puts stderr "#### req waiting for response: ($waitfor_resp)"
			lassign [try $waitfor_resp] r o

			after cancel $timeout_afterid; set timeout_afterid	""

			return -options $o $r
		}

		#>>>
	}

	#>>>
}

# vim: foldmethod=marker foldmarker=<<<,>>> ts=4 shiftwidth=4
