/*
 * @LastEditors: zhanghengxin ezreal.zhang@icewhale.org
 * @LastEditTime: 2023/3/31 上午11:35
 * @FilePath: /CasaOS-UI/src/plugins/vee-validate.js
 * @Description:
 *
 * Copyright (c) 2023 by IceWhale, All Rights Reserved.

 */

import { isURL } from 'validator';
import { builtInRules, extend } from '@/plugins/validation';

const { confirmed, email, length, min, required } = builtInRules;
// import isValidHostname from 'is-valid-hostname';
import validate from 'uuid-validate';

function isValidContainerName(value) {
	let reg = /^[a-z0-9A-Z\-_]+$/;
	return reg.test(value) && value.length <= 32;
}

extend("required", {
	...required,
	message: "This field is required"
});

extend("email", {
	...email,
	message: "This field must be a valid email"
});

extend("confirmed", {
	...confirmed,
	message: "This field confirmation does not match"
});

extend("length", {
	...length,
	message: "This field must have 2 options"
});

extend("min", {
	...min,
	message: "This field must have more than {length} characters"
});

extend('ContainerName', {
	validate: (value) => isValidContainerName(value),
	message: 'Use only letters, numbers, - and _ (up to 32 characters).',
});

extend('uuid', {
	validate: (value) => validate(value),
	message: 'You entered an invalid share ID',
});

extend('url', {
	validate: value => isURL(value, { require_protocol: true }),
	message: 'The field mast be a valid url',
})

extend('yaml_port', {
	// A port (1-65535) or a range of them, for example "8080" or "8000-8010", with an optional host IP
	// in front ("192.168.1.10:8080")
	validate: value => {
		const match = /^(?:(\d{1,3}(?:\.\d{1,3}){3}):)?(\d{1,5})(?:-(\d{1,5}))?$/.exec(String(value ?? '').trim())
		if (!match) return false
		const [, ip, from, to] = match
		if (ip && ip.split('.').some(part => Number(part) > 255)) return false
		const port = (p) => Number(p) >= 1 && Number(p) <= 65535
		return port(from) && (to === undefined || (port(to) && Number(to) >= Number(from)))
	},
	message: 'Enter a port such as 8080, a range such as 8000-8010, or IP:port.',
})

extend('not_in_ports', {
	validate: (value, isInPortsResult) => {
		// true : 满足，成功
		// false : 不满足， 报错
		// return true
		return isInPortsResult?.[0] === 'false'
	},
	message: 'This port is already used by another app or service.',
})