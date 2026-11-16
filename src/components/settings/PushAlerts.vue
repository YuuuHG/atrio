<script>
// Push alerts settings, in the settings panel. Atrio writes alerts.conf through the CasaOS file
// API; atrio-alerts (installed by scripts/install.sh) reads it every 5 minutes and sends the
// warnings to ntfy, Gotify or Apprise. "Send a test" goes through the server, like the real alerts.
import { ice_i18n } from '@/mixins/base/common-i18n'

const STATE = '/var/lib/casaos/atrio'
const CONF = `${STATE}/alerts.conf`
const STATUS = `${STATE}/alerts-status.json`
const TEST = `${STATE}/alerts-test`
const INSTALL = 'curl -fsSL https://raw.githubusercontent.com/peppeaiello/atrio/main/scripts/install.sh | sudo bash'

const DEFAULTS = {
	ENABLED: '0',
	SERVICE: 'ntfy',
	URL: 'https://ntfy.sh',
	TOPIC: '',
	TOKEN: '',
	DISK: '1',
	HEALTH: '1',
	TEMP: '1',
	APPS: '1',
	APP_UPDATES: '1',
	APP_DOWN: '1',
	UPDATES: '1',
	DISK_LIMIT: '90',
	TEMP_LIMIT: '85',
	QUIET: '0',
	QUIET_FROM: '23:00',
	QUIET_TO: '07:00',
	MUTE: '',
	// Set from the hardware panel, kept here so that saving the alerts does not drop it
	SELFTEST: '1',
}

function randomTopic() {
	const bytes = crypto.getRandomValues(new Uint8Array(9))
	return `atrio-${Array.from(bytes, (b) => b.toString(36).padStart(2, '0')).join('').slice(0, 14)}`
}

export default {
	name: 'PushAlerts',
	compatConfig: { MODE: 3 },
	data() {
		return {
			conf: { ...DEFAULTS },
			// null: still loading; false: atrio-alerts is not installed on this server
			installed: null,
			status: null,
			saving: false,
			testing: false,
			testResult: null,
			saved: false,
			install: INSTALL,
			services: [{ id: 'ntfy', name: 'ntfy' }, { id: 'gotify', name: 'Gotify' }, { id: 'apprise', name: 'Apprise' }],
			// Installed apps, for the ones without alerts: { name, title }
			apps: [],
		}
	},
	computed: {
		enabled: {
			get() {
				return this.conf.ENABLED === '1'
			},
			set(value) {
				this.conf.ENABLED = value ? '1' : '0'
				this.save()
			},
		},
		isGotify() {
			return this.conf.SERVICE === 'gotify'
		},
		isApprise() {
			return this.conf.SERVICE === 'apprise'
		},
		urlPlaceholder() {
			if (this.isGotify) return 'https://gotify.example.home'
			if (this.isApprise) return 'http://apprise.example.home:8000'
			return 'https://ntfy.sh'
		},
		urlValid() {
			return /^https?:\/\/[A-Za-z0-9.:/_~%-]+$/.test(this.conf.URL)
		},
		topicValid() {
			return this.isGotify || /^[A-Za-z0-9_-]{1,64}$/.test(this.conf.TOPIC)
		},
		tokenValid() {
			// Apprise has no token: whatever an earlier service left in the field is not used
			if (this.isApprise) return true
			return /^[A-Za-z0-9._-]{0,128}$/.test(this.conf.TOKEN) && (!this.isGotify || this.conf.TOKEN !== '')
		},
		limitsValid() {
			const disk = Number(this.conf.DISK_LIMIT)
			const temp = Number(this.conf.TEMP_LIMIT)
			const time = /^([01][0-9]|2[0-3]):[0-5][0-9]$/
			return disk >= 50 && disk <= 99 && temp >= 60 && temp <= 110 && time.test(this.conf.QUIET_FROM) && time.test(this.conf.QUIET_TO)
		},
		ready() {
			return this.urlValid && this.topicValid && this.tokenValid && this.limitsValid
		},
		muted() {
			return this.conf.MUTE ? this.conf.MUTE.split(',') : []
		},
		checks() {
			return [
				{ key: 'DISK', label: this.$t('Disk almost full') },
				{ key: 'HEALTH', label: this.$t('Disk health problems') },
				{ key: 'TEMP', label: this.$t('Processor running hot') },
				{ key: 'APPS', label: this.$t('Apps installed or removed') },
				{ key: 'APP_UPDATES', label: this.$t('Apps updated') },
				{ key: 'APP_DOWN', label: this.$t('Apps that stop working, and when they are back') },
				{ key: 'UPDATES', label: this.$t('New Atrio versions') },
			]
		},
		statusText() {
			if (!this.status) return ''
			if (this.status.state === 'error') return this.$t('Last attempt failed: {message}', { message: this.status.message })
			if (this.status.state === 'ok' && this.status.last_sent) return this.$t('Last alert sent: {title}', { title: this.status.last_sent })
			if (this.status.state === 'ok') return this.$t('Checking every 5 minutes')
			return ''
		},
	},
	mounted() {
		this.load()
		this.loadApps()
	},
	beforeUnmount() {
		clearTimeout(this.pollTimer)
	},
	methods: {
		async read(path) {
			try {
				const res = await this.$api.file.getContent(path)
				return res.data.success === 200 ? String(res.data.data ?? '') : null
			}
			catch (e) {
				return null
			}
		},
		async load() {
			const [conf, status] = await Promise.all([this.read(CONF), this.read(STATUS)])
			// The service writes its status on its first run, right after install.sh
			this.installed = status !== null
			try {
				this.status = status ? JSON.parse(status) : null
			}
			catch (e) {
				this.status = null
			}
			if (conf) {
				for (const line of conf.split('\n')) {
					const at = line.indexOf('=')
					const key = line.slice(0, at)
					if (at > 0 && key in DEFAULTS) this.conf[key] = line.slice(at + 1).trim()
				}
			}
		},
		async loadApps() {
			try {
				const grid = (await this.$openAPI.appGrid.getAppGrid()).data.data || []
				this.apps = grid.filter((app) => app.app_type === 'v2app')
					.map((app) => ({ name: app.name, title: typeof app.title === 'object' ? ice_i18n(app.title) : app.title || app.name }))
					.sort((a, b) => a.title.localeCompare(b.title))
			}
			catch (e) {
				this.apps = []
			}
		},
		toggleMute(name) {
			const muted = this.muted.includes(name) ? this.muted.filter((item) => item !== name) : [...this.muted, name]
			this.conf.MUTE = muted.join(',')
		},
		setService(service) {
			if (this.conf.SERVICE === service) return
			this.conf.SERVICE = service
			// ntfy works out of the box with its public server; Gotify and Apprise are always self-hosted
			if (service === 'ntfy' && !this.conf.URL) this.conf.URL = DEFAULTS.URL
			if (service !== 'ntfy' && this.conf.URL === DEFAULTS.URL) this.conf.URL = ''
		},
		newTopic() {
			this.conf.TOPIC = randomTopic()
		},
		text() {
			const language = (this.$i18n.locale || '').startsWith('it') ? 'it' : 'en'
			return `${Object.entries(this.conf).map(([key, value]) => `${key}=${String(value).replace(/[\r\n]/g, '')}`).join('\n')}\nLANGUAGE=${language}\n`
		},
		// Saves through the CasaOS file API; the file is created the first time
		async save() {
			if (this.conf.ENABLED === '1' && !this.ready) return false
			this.saving = true
			this.saved = false
			try {
				if ((await this.read(CONF)) === null) await this.$api.file.create(CONF)
				const res = await this.$api.file.update(CONF, this.text())
				if (res.data.success !== 200) throw new Error('save')
				this.saved = true
				return true
			}
			catch (e) {
				this.$buefy.toast.open({ message: this.$t('Could not save the push alert settings'), type: 'is-danger' })
				return false
			}
			finally {
				this.saving = false
			}
		},
		async test() {
			if (!this.ready || !(await this.save())) return
			this.testing = true
			this.testResult = null
			const token = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`
			try {
				const temp = `${TEST}.tmp`
				await this.$api.file.create(temp)
				await this.$api.file.update(temp, token)
				const renamed = await this.$api.file.rename(temp, TEST)
				if (renamed.data.success !== 200) throw new Error('request')
			}
			catch (e) {
				this.testing = false
				this.testResult = { ok: false, message: this.$t('Could not reach the alert service on the server') }
				return
			}
			const started = Date.now()
			const poll = async () => {
				const raw = await this.read(STATUS)
				let status = null
				try {
					status = raw ? JSON.parse(raw) : null
				}
				catch (e) {
					status = null
				}
				if (status?.token === token) {
					this.status = status
					this.testing = false
					this.testResult = status.state === 'ok'
						? { ok: true, message: this.$t('Test sent: check your phone') }
						: { ok: false, message: status.message }
					return
				}
				if (Date.now() - started > 40000) {
					this.testing = false
					this.testResult = { ok: false, message: this.$t('The server did not answer') }
					return
				}
				this.pollTimer = setTimeout(poll, 1500)
			}
			this.pollTimer = setTimeout(poll, 1500)
		},
		copyInstall() {
			navigator.clipboard?.writeText(this.install)
			this.$buefy.toast.open({ message: this.$t('Copied'), type: 'is-success' })
		},
	},
}
</script>

<template>
	<section class="atrio-settings-section atrio-push">
		<h3>{{ $t('Push notifications') }}</h3>

		<p v-if="installed === false" class="atrio-push-note">
			{{ $t('The alert service is not installed on this server yet. Run the install command again on the server to add it:') }}
			<button class="atrio-push-code" type="button" :title="$t('Copy')" @click="copyInstall">{{ install }}</button>
		</p>

		<template v-else-if="installed">
			<div class="atrio-setting-row">
				<b-icon icon="bell-ring-outline" pack="mdi" size="is-20" />
				<span class="atrio-setting-label">
					{{ $t('Send alerts to my phone') }}
					<small class="atrio-setting-note">{{ $t('Even when Atrio is closed, through ntfy, Gotify or Apprise') }}</small>
				</span>
				<b-switch v-model="enabled" :disabled="!ready && !enabled" class="mr-0" />
			</div>

			<div class="atrio-push-form">
				<div class="atrio-segmented" role="radiogroup" :aria-label="$t('Service')">
					<button
						v-for="service in services" :key="service.id" :aria-checked="conf.SERVICE === service.id" :class="{ 'is-active': conf.SERVICE === service.id }"
						role="radio" type="button" @click="setService(service.id)"
					>
						{{ service.name }}
					</button>
				</div>

				<label>
					<span>{{ $t('Server') }}</span>
					<input v-model.trim="conf.URL" :placeholder="urlPlaceholder" class="atrio-push-input" type="url">
					<small v-if="conf.URL && !urlValid" class="atrio-push-error">{{ $t('Enter an address that starts with http:// or https://') }}</small>
				</label>

				<label v-if="isApprise">
					<span>{{ $t('Configuration key') }}</span>
					<input v-model.trim="conf.TOPIC" class="atrio-push-input" placeholder="atrio" type="text">
					<small class="atrio-push-hint">{{ $t('The key of a configuration saved on your Apprise API server: every service in it, such as Discord, Telegram or e-mail, gets the alerts.') }}</small>
					<small v-if="conf.TOPIC && !topicValid" class="atrio-push-error">{{ $t('Use letters, numbers, - and _ (up to 64 characters).') }}</small>
				</label>

				<label v-else-if="!isGotify">
					<span>{{ $t('Topic') }}</span>
					<span class="atrio-push-inline">
						<input v-model.trim="conf.TOPIC" class="atrio-push-input" placeholder="atrio-…" type="text">
						<button class="atrio-button is-small" type="button" @click="newTopic">{{ $t('Generate') }}</button>
					</span>
					<small class="atrio-push-hint">{{ $t('Anyone who knows a topic on a public server can read it: use a name that is hard to guess, or your own server. Subscribe to the same topic in the ntfy app.') }}</small>
					<small v-if="conf.TOPIC && !topicValid" class="atrio-push-error">{{ $t('Use letters, numbers, - and _ (up to 64 characters).') }}</small>
				</label>

				<label v-if="!isApprise">
					<span>{{ isGotify ? $t('Application token') : $t('Access token (optional)') }}</span>
					<input v-model.trim="conf.TOKEN" autocomplete="off" class="atrio-push-input" type="password">
					<small v-if="isGotify" class="atrio-push-hint">{{ $t('Create an application in Gotify and paste its token here.') }}</small>
				</label>

				<fieldset class="atrio-push-checks">
					<legend>{{ $t('What to send') }}</legend>
					<label v-for="check in checks" :key="check.key">
						<input :checked="conf[check.key] === '1'" type="checkbox" @change="conf[check.key] = $event.target.checked ? '1' : '0'">
						{{ check.label }}
					</label>
				</fieldset>

				<fieldset class="atrio-push-checks">
					<legend>{{ $t('Quiet hours') }}</legend>
					<label>
						<input :checked="conf.QUIET === '1'" type="checkbox" @change="conf.QUIET = $event.target.checked ? '1' : '0'">
						{{ $t('Hold back what is not urgent') }}
					</label>
					<div v-if="conf.QUIET === '1'" class="atrio-push-row">
						<span>{{ $t('From') }}</span>
						<input v-model="conf.QUIET_FROM" class="atrio-push-input is-short" required type="time">
						<span>{{ $t('to') }}</span>
						<input v-model="conf.QUIET_TO" class="atrio-push-input is-short" required type="time">
					</div>
					<small v-if="conf.QUIET === '1'" class="atrio-push-hint">{{ $t('What comes in those hours arrives in one message when they end. A disk that may fail soon is sent at once.') }}</small>
				</fieldset>

				<fieldset class="atrio-push-checks">
					<legend>{{ $t('Limits') }}</legend>
					<div class="atrio-push-row">
						<span>{{ $t('Disk almost full above') }}</span>
						<input v-model="conf.DISK_LIMIT" class="atrio-push-input is-number" max="99" min="50" type="number">
						<span>%</span>
					</div>
					<div class="atrio-push-row">
						<span>{{ $t('Processor hot above') }}</span>
						<input v-model="conf.TEMP_LIMIT" class="atrio-push-input is-number" max="110" min="60" type="number">
						<span>°C</span>
					</div>
					<small v-if="!limitsValid" class="atrio-push-hint is-error">{{ $t('The disk limit goes from 50 to 99%, the processor from 60 to 110 °C.') }}</small>
				</fieldset>

				<fieldset v-if="apps.length" class="atrio-push-checks">
					<legend>{{ $t('Apps without alerts') }}</legend>
					<div class="atrio-push-apps">
						<button
							v-for="app in apps" :key="app.name" :aria-pressed="muted.includes(app.name)" :class="{ 'is-muted': muted.includes(app.name) }"
							type="button" @click="toggleMute(app.name)"
						>
							<b-icon :icon="muted.includes(app.name) ? 'bell-off-outline' : 'bell-outline'" pack="mdi" size="is-16" />{{ app.title }}
						</button>
					</div>
					<small class="atrio-push-hint">{{ $t('Their installs, updates and problems are still in Activity and on their tiles.') }}</small>
				</fieldset>

				<div class="atrio-push-actions">
					<button :disabled="!ready || saving" class="atrio-button is-small" type="button" @click="save">
						{{ saved ? $t('Saved') : $t('Save') }}
					</button>
					<button :disabled="!ready || testing" class="atrio-button is-small is-primary" type="button" @click="test">
						{{ testing ? $t('Sending…') : $t('Send a test') }}
					</button>
				</div>
				<p v-if="testResult" :class="testResult.ok ? 'is-ok' : 'is-error'" class="atrio-push-result" role="status">{{ testResult.message }}</p>
				<p v-else-if="statusText && enabled" class="atrio-push-hint">{{ statusText }}</p>
			</div>
		</template>
	</section>
</template>

<style lang="scss">
.atrio-push {
	.atrio-push-form {
		display: flex;
		flex-direction: column;
		gap: 0.75rem;
		padding: 0.25rem 0.5rem 0.5rem;

		> label,
		.atrio-push-checks {
			display: flex;
			flex-direction: column;
			gap: 0.375rem;

			> span:first-child,
			legend {
				color: var(--atrio-text-soft);
				font-size: 0.8125rem;
				font-weight: 600;
			}
		}

		.atrio-segmented {
			align-self: flex-start;
		}
	}

	.atrio-push-input {
		width: 100%;
		height: 2.25rem;
		padding: 0 0.75rem;
		border: 1px solid rgba(255, 255, 255, 0.12);
		border-radius: 0.75rem;
		background: rgba(255, 255, 255, 0.06);
		color: var(--atrio-text);
		font: inherit;
		font-size: 0.875rem;
		outline: none;

		&:focus {
			border-color: var(--atrio-accent);
		}
	}

	.atrio-push-inline {
		display: flex;
		gap: 0.5rem;
		align-items: center;

		.atrio-button {
			flex-shrink: 0;
		}
	}

	.atrio-push-row {
		display: flex;
		flex-wrap: wrap;
		gap: 0.5rem;
		align-items: center;
		color: var(--atrio-text);
		font-size: 0.875rem;
	}

	.atrio-push-input.is-short {
		width: 7rem;
		color-scheme: dark;
	}

	.atrio-push-input.is-number {
		width: 5rem;
	}

	.atrio-push-hint.is-error {
		color: #fca5a5;
	}

	.atrio-push-apps {
		display: flex;
		flex-wrap: wrap;
		gap: 0.375rem;

		button {
			display: flex;
			gap: 0.25rem;
			align-items: center;
			min-height: 2rem;
			padding: 0 0.75rem;
			border: 1px solid rgba(255, 255, 255, 0.12);
			border-radius: 999px;
			background: rgba(255, 255, 255, 0.06);
			color: var(--atrio-text);
			font: inherit;
			font-size: 0.8125rem;
			cursor: pointer;

			&.is-muted {
				background: rgba(248, 113, 113, 0.14);
				color: #fecaca;
				text-decoration: line-through;
			}
		}
	}

	.atrio-push-checks {
		margin: 0;
		padding: 0;
		border: 0;

		label {
			display: flex;
			gap: 0.5rem;
			align-items: center;
			color: var(--atrio-text);
			font-size: 0.875rem;
			cursor: pointer;

			input {
				accent-color: var(--atrio-accent);
			}
		}
	}

	.atrio-push-actions {
		display: flex;
		gap: 0.5rem;
		justify-content: flex-end;
	}

	.atrio-push-hint,
	.atrio-push-note {
		color: var(--atrio-text-muted);
		font-size: 0.75rem;
		line-height: 1.4;
	}

	.atrio-push-note {
		padding: 0.25rem 0.5rem 0.5rem;
		font-size: 0.8125rem;
	}

	.atrio-push-code {
		display: block;
		width: 100%;
		margin-top: 0.5rem;
		padding: 0.5rem 0.75rem;
		border: 0;
		border-radius: 0.5rem;
		background: rgba(0, 0, 0, 0.35);
		color: var(--atrio-text);
		font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
		font-size: 0.75rem;
		text-align: left;
		word-break: break-all;
		cursor: copy;
	}

	.atrio-push-error {
		color: #fca5a5;
		font-size: 0.75rem;
	}

	.atrio-push-result {
		font-size: 0.8125rem;
		font-weight: 600;

		&.is-ok {
			color: #86efac;
		}

		&.is-error {
			color: #fca5a5;
		}
	}
}
</style>
