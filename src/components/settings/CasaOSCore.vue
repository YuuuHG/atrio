<script>
// The fix for the CasaOS core, in the Updates section of the settings. CasaOS v0.4.15 stops several
// times a day (CasaOS issue #2581); atrio-core on the server puts Atrio's build of the same version,
// with the bug fixed, in place of IceWhale's (see casaos-core/ and scripts/atrio-core). It writes its
// state in core-status.json, and takes "on" or "off" from core-request.
import api from '@/service/api.js'

const STATE = '/var/lib/casaos/atrio'
const STATUS = `${STATE}/core-status.json`
const REQUEST = `${STATE}/core-request`
const ISSUE = 'https://github.com/IceWhaleTech/CasaOS/issues/2581'
const POLL_MS = 2000
// Downloading the core on a slow line and waiting for CasaOS to stay up
const WAIT_MS = 5 * 60 * 1000

async function readStatus() {
	try {
		const res = await api.file.getContent(STATUS)
		return res.data.success === 200 ? JSON.parse(String(res.data.data ?? '')) : null
	}
	catch (e) {
		// CasaOS restarts while the core changes: the next read gets it
		return null
	}
}

export default {
	name: 'CasaOSCore',
	compatConfig: { MODE: 3 },
	data() {
		return {
			status: null,
			working: false,
			error: '',
			issue: ISSUE,
			// Drawn again when it must go back to what is true on the server: the switch keeps its own state
			switchKey: 0,
		}
	},
	computed: {
		// Nothing to show where the services are older, or this copy of Atrio has no fixed core
		shown() {
			return !!this.status && this.status.state !== 'unavailable'
		},
		on() {
			return this.status?.state === 'fixed'
		},
		// Only where the fix applies: IceWhale's v0.4.15 or Atrio's build of it
		switchable() {
			return ['fixed', 'off', 'failed'].includes(this.status?.state)
		},
		note() {
			if (this.working || this.status?.state === 'working') return this.$t('Changing the CasaOS core, CasaOS restarts…')
			switch (this.status?.state) {
				case 'fixed': return this.$t('On: CasaOS runs Atrio\'s build of v0.4.15, without the bug that makes it stop several times a day')
				case 'off': return this.$t('Off: CasaOS runs IceWhale\'s original v0.4.15, which stops several times a day')
				default: return this.status?.message ? this.$t(this.status.message) : ''
			}
		},
	},
	async mounted() {
		this.status = await readStatus()
	},
	methods: {
		toggle(value) {
			if (value) {
				this.send('on')
				return
			}
			this.$buefy.dialog.confirm({
				title: this.$t('Turn off the fix for CasaOS?'),
				message: this.$t('CasaOS goes back to IceWhale\'s original core, which stops and restarts by itself several times a day. Turn it off to connect a new Google Drive, Dropbox or OneDrive, then turn it back on: drives already connected keep working. CasaOS restarts, so the page may not answer for a few seconds.'),
				confirmText: this.$t('Turn the fix off'),
				cancelText: this.$t('Cancel'),
				type: 'is-warning',
				onConfirm: () => this.send('off'),
				// The switch goes back to what is true on the server
				onCancel: () => { this.switchKey++ },
			})
		},
		async send(asked) {
			const before = this.status?.time
			this.working = true
			this.error = ''
			try {
				const temp = `${REQUEST}.tmp`
				await api.file.create(temp)
				const written = await api.file.update(temp, `${asked}\n`)
				const renamed = written.data.success === 200 && await api.file.rename(temp, REQUEST)
				if (!renamed || renamed.data.success !== 200) throw new Error('Could not reach the service on the server')
				const until = Date.now() + WAIT_MS
				for (;;) {
					await new Promise((resolve) => setTimeout(resolve, POLL_MS))
					const status = await readStatus()
					if (status && status.time !== before && status.state !== 'working') {
						this.status = status
						break
					}
					if (Date.now() > until) throw new Error('The service on the server did not answer. Check Activity to see what was done.')
				}
			}
			catch (e) {
				this.error = this.$t(e.message)
				this.status = (await readStatus()) || this.status
			}
			finally {
				this.working = false
				this.switchKey++
			}
		},
	},
}
</script>

<template>
	<div v-if="shown" class="atrio-setting-row">
		<b-icon :icon="on ? 'shield-check-outline' : 'shield-alert-outline'" pack="mdi" size="is-20" />
		<span class="atrio-setting-label">
			{{ $t('Fix for CasaOS crashes') }}
			<small class="atrio-setting-note">
				{{ note }}
				<a :href="issue" rel="noopener noreferrer" target="_blank">{{ $t('Details') }}</a>
			</small>
			<small v-if="error" class="atrio-setting-note has-text-danger">{{ error }}</small>
		</span>
		<b-switch
			v-if="switchable" :key="switchKey" :disabled="working || status.state === 'working'" :model-value="on" class="mr-0"
			@update:model-value="toggle"
		/>
	</div>
</template>
