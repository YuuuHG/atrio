// Copies text and says whether it worked: on plain HTTP in the home network the browser has no
// clipboard API, and clipboard-copy falls back to the old copy command, which can fail too.
import copy from 'clipboard-copy'

export async function copyText(vm, text, message = 'Copied') {
	try {
		await copy(text)
		vm.$buefy.toast.open({ message: vm.$t(message), type: 'is-success' })
	}
	catch (e) {
		vm.$buefy.toast.open({ message: vm.$t('Could not copy: select the text and copy it by hand'), type: 'is-danger' })
	}
}
