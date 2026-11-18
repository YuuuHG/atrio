<script>
// A QR code drawn as one SVG path, dark on white so every phone camera reads it
import qrcode from 'qrcode-generator'

export default {
	name: 'QrCode',
	compatConfig: { MODE: 3 },
	props: {
		text: { type: String, required: true },
		// What the code opens, for screen readers
		label: { type: String, required: true },
	},
	computed: {
		code() {
			const qr = qrcode(0, 'M')
			qr.addData(this.text)
			qr.make()
			const count = qr.getModuleCount()
			let path = ''
			for (let row = 0; row < count; row++) {
				for (let col = 0; col < count; col++) {
					if (qr.isDark(row, col)) path += `M${col + 4},${row + 4}h1v1h-1z`
				}
			}
			// Four modules of white around it, as the standard asks
			return { size: count + 8, path }
		},
	},
}
</script>

<template>
	<svg :aria-label="label" :viewBox="`0 0 ${code.size} ${code.size}`" class="atrio-qr" role="img" shape-rendering="crispEdges">
		<rect :height="code.size" :width="code.size" fill="#fff" />
		<path :d="code.path" fill="#0f172a" />
	</svg>
</template>

<style lang="scss">
.atrio-qr {
	display: block;
	width: 100%;
	height: auto;
	border-radius: 0.75rem;
}
</style>
