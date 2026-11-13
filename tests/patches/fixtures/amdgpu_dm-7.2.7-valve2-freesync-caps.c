// SPDX-License-Identifier: GPL-2.0-only
// amdgpu_dm_update_freesync_caps() as in Valve linux-integration 7.2.7-valve2
// (drivers/gpu/drm/amd/display/amdgpu_dm/amdgpu_dm.c), for `git apply --check`
// of patches/kernel/0001-*.patch in tests/patches/kernel-patches.bats.
void amdgpu_dm_update_freesync_caps(struct drm_connector *connector,
				    const struct drm_edid *drm_edid, bool do_mccs)
{
	struct amdgpu_dm_connector *amdgpu_dm_connector =
			to_amdgpu_dm_connector(connector);
	struct dm_connector_state *dm_con_state = NULL;
	struct dc_sink *sink;
	struct amdgpu_device *adev = drm_to_adev(connector->dev);
	struct amdgpu_hdmi_vsdb_info vsdb_info = {0};
	struct amdgpu_hdmi_vsdb_info vsdb_did = {0};
	struct drm_hdmi_vrr_cap hdmi_vrr = {0};
	struct dpcd_caps dpcd_caps = {0};
	const struct edid *edid;
	bool freesync_on_desktop = false;
	bool freesync_capable = false;
	bool pcon_allowed = false;
	bool is_pcon = false;

	if (!connector->state) {
		drm_err(adev_to_drm(adev), "%s - Connector has no state", __func__);
		goto update;
	}

	sink = amdgpu_dm_connector->dc_sink ?
		amdgpu_dm_connector->dc_sink :
		amdgpu_dm_connector->dc_em_sink;

	drm_edid_connector_update(connector, drm_edid);

	if (!drm_edid || !sink) {
		dm_con_state = to_dm_connector_state(connector->state);

		amdgpu_dm_connector->min_vfreq = 0;
		amdgpu_dm_connector->max_vfreq = 0;
		freesync_capable = false;

		goto update;
	}

	dm_con_state = to_dm_connector_state(connector->state);

	if (!adev->dm.freesync_module || !dc_supports_vrr(sink->ctx->dce_version))
		goto update;

	/* Gather all data */
	edid = drm_edid_raw(drm_edid); // FIXME: Get rid of drm_edid_raw()
	parse_amd_vsdb_cea(amdgpu_dm_connector, edid, &vsdb_info);
	hdmi_vrr = connector->display_info.hdmi.vrr_cap;

	if (amdgpu_dm_connector->dc_link) {
		dpcd_caps = amdgpu_dm_connector->dc_link->dpcd_caps;
		is_pcon = dpcd_caps.dongle_type == DISPLAY_DONGLE_DP_HDMI_CONVERTER;
		pcon_allowed = dm_helpers_is_vrr_pcon_allowed(
			amdgpu_dm_connector->dc_link, connector->dev);
	}

	/* DP & eDP excluding PCONs */
	if ((sink->sink_signal == SIGNAL_TYPE_EDP ||
	     sink->sink_signal == SIGNAL_TYPE_DISPLAY_PORT) && !is_pcon) {
		/* Some eDP panels only have the refresh rate range info in DisplayID */
		if (is_monitor_range_invalid(connector))
			parse_edid_displayid_vrr(connector, edid);
		/*
		 * Many monitors expose AMD vsdb in CAE even for DP and their
		 * monitor ranges do not contain Range Limits Only flag
		 */
		if (is_monitor_range_invalid(connector))
			monitor_range_from_vsdb(&connector->display_info, &vsdb_info);

		/* Try extending range if found in AMD vsdb */
		extend_range_from_vsdb(&connector->display_info, &vsdb_info);

		if (dpcd_caps.allow_invalid_MSA_timing_param)
			freesync_capable = copy_range_to_amdgpu_connector(connector);

		/* eDP */
		get_amd_vsdb(amdgpu_dm_connector, &vsdb_did);
		if (vsdb_did.replay_mode) {
			amdgpu_dm_connector->vsdb_info.replay_mode = vsdb_did.replay_mode;
			amdgpu_dm_connector->vsdb_info.amd_vsdb_version = vsdb_did.amd_vsdb_version;
			amdgpu_dm_connector->as_type = ADAPTIVE_SYNC_TYPE_EDP;
		}

	/* HDMI */
	} else if (sink->sink_signal == SIGNAL_TYPE_HDMI_TYPE_A) {
		/* Prefer HDMI VRR */
		if (hdmi_vrr.supported) {
			amdgpu_dm_connector->as_type = ADAPTIVE_SYNC_TYPE_HDMI;
			monitor_range_from_hdmi(&connector->display_info, &vsdb_info);
		} else if (vsdb_info.freesync_supported)
			monitor_range_from_vsdb(&connector->display_info, &vsdb_info);

		freesync_capable = copy_range_to_amdgpu_connector(connector);
		freesync_on_desktop = freesync_capable;

	/* DP -> HDMI PCON */
	} else if (pcon_allowed) {
		/* Prefer HDMI VRR */
		if (hdmi_vrr.supported)
			monitor_range_from_hdmi(&connector->display_info, &vsdb_info);
		else if (vsdb_info.freesync_supported) {
			amdgpu_dm_connector->vsdb_info = vsdb_info;
			monitor_range_from_vsdb(&connector->display_info, &vsdb_info);
		}

		amdgpu_dm_connector->pack_sdp_v1_3 = true;
		amdgpu_dm_connector->as_type = ADAPTIVE_SYNC_TYPE_PCON_ALLOWED;
		freesync_capable = copy_range_to_amdgpu_connector(connector);
		freesync_on_desktop = freesync_capable;
	}

	/* Handle MCCS */
	if (do_mccs) {
		sink->edid_caps.freesync_vcp_code = vsdb_info.freesync_mccs_vcp_code;

		dm_helpers_read_mccs_caps(adev->dm.dc->ctx, amdgpu_dm_connector->dc_link, sink);

		if (sink->edid_caps.freesync_vcp_code && !sink->mccs_caps.freesync_supported)
			freesync_capable = false;

		if (sink->mccs_caps.freesync_supported && freesync_capable)
			dm_helpers_mccs_vcp_set(adev->dm.dc->ctx, amdgpu_dm_connector->dc_link, sink);
	}

update:
	if (dm_con_state) {
		dm_con_state->freesync_capable = freesync_capable;
		dm_con_state->freesync_on_desktop_capable = freesync_on_desktop;
	}

	if (connector->state && amdgpu_dm_connector->dc_link && !freesync_capable &&
	    amdgpu_dm_connector->dc_link->replay_settings.config.replay_supported) {
		amdgpu_dm_connector->dc_link->replay_settings.config.replay_supported = false;
		amdgpu_dm_connector->dc_link->replay_settings.replay_feature_enabled = false;
	}

	if (connector->vrr_capable_property)
		drm_connector_set_vrr_capable_property(connector, freesync_capable);

	if (connector->passive_vrr_capable_property)
		drm_connector_set_passive_vrr_capable_property(connector, freesync_on_desktop);

	amdgpu_dm_connector->hdmi_allm_capable = connector->display_info.hdmi.allm;
	if (connector->allm_capable_property)
		drm_connector_set_allm_capable_property(
			connector, connector->display_info.hdmi.allm);
}
