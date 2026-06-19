/**
 * OxiCloud - People (faces)
 *
 * A grid of identity clusters from GET /api/people; clicking a person shows
 * their photos (reusing the photos lightbox). Faces are detected + clustered
 * server-side; this view is read-mostly (list, drill-in, rename).
 *
 * The feature is gated on OXICLOUD_ENABLE_FACES — when it is off the API 404s
 * and the view shows a short "disabled" hint (and the Places/People sub-nav
 * hides the People tab via a capability probe).
 */

import { Modal } from '../../components/modal.js';
import { getCsrfHeaders } from '../../core/csrf.js';
import { i18n } from '../../core/i18n.js';
import { photosLightbox } from './photosLightbox.js';

/** @import {FileItem} from '../../core/types.js' */
/** @typedef {{id: string, name?: string, cover_file_id?: string, face_count: number, is_hidden: boolean}} PersonItem */

export const peopleView = {
    /** @type {HTMLElement|null} */
    _container: null,

    _headers() {
        return getCsrfHeaders();
    },

    /** Ensure the container exists (sibling in .content-area). */
    _mount() {
        const ca = document.querySelector('.content-area');
        if (!ca) return;
        if (!this._container) {
            const el = document.createElement('div');
            el.id = 'people-container';
            el.className = 'people-container';
            ca.appendChild(el);
            this._container = el;
        }
    },

    async show() {
        this._mount();
        if (!this._container) return;
        this._container.classList.add('active');
        await this._renderList();
    },

    hide() {
        this._container?.classList.remove('active');
    },

    async _renderList() {
        if (!this._container) return;
        this._container.innerHTML = '<div class="people-loading"><i class="fas fa-spinner"></i></div>';
        try {
            const res = await fetch('/api/people', { credentials: 'include', headers: this._headers() });
            if (!res.ok) {
                this._renderHint(i18n.t('people.disabled'));
                return;
            }
            /** @type {PersonItem[]} */
            const people = await res.json();
            if (!people.length) {
                this._renderHint(i18n.t('people.empty'));
                return;
            }
            let html = '<div class="people-grid">';
            for (const p of people) {
                const cover = p.cover_file_id ? `/api/files/${p.cover_file_id}/thumbnail/icon` : '';
                const name = p.name || i18n.t('people.unnamed');
                html += `<button class="person-tile" type="button" data-id="${this._escAttr(p.id)}" data-name="${this._escAttr(name)}">`;
                html += `<span class="person-avatar" style="background-image:url(${cover})"></span>`;
                html += `<span class="person-name">${this._escHtml(name)}</span>`;
                html += `<span class="person-count">${p.face_count}</span>`;
                html += '</button>';
            }
            html += '</div>';
            this._container.innerHTML = html;
            this._container.querySelectorAll('.person-tile').forEach((t) => {
                const el = /** @type {HTMLElement} */ (t);
                el.addEventListener('click', () => this._openPerson(el.dataset.id || '', el.dataset.name || ''));
            });
        } catch (err) {
            console.error('People load failed:', err);
            this._renderHint(i18n.t('people.disabled'));
        }
    },

    /**
     * @param {string} personId
     * @param {string} name
     */
    async _openPerson(personId, name) {
        if (!this._container) return;
        this._container.innerHTML =
            '<div class="people-toolbar">' +
            `<button class="people-back" type="button" title="${this._escAttr(i18n.t('people.back'))}"><i class="fas fa-arrow-left"></i></button>` +
            `<h2 class="people-title">${this._escHtml(name)}</h2>` +
            `<button class="people-rename" type="button" title="${this._escAttr(i18n.t('people.rename_title'))}"><i class="fas fa-pen"></i></button>` +
            '</div>' +
            '<div class="photos-grid" id="person-photos"></div>';
        /** @type {HTMLButtonElement} */ (this._container.querySelector('.people-back')).onclick = () => this._renderList();
        /** @type {HTMLButtonElement} */ (this._container.querySelector('.people-rename')).onclick = () => this._rename(personId, name);

        try {
            const res = await fetch(`/api/people/${personId}/photos`, { credentials: 'include', headers: this._headers() });
            if (!res.ok) return;
            /** @type {string[]} */
            const fileIds = await res.json();
            // Minimal FileItems so the lightbox can open them by id.
            const items = fileIds.map(
                (id) =>
                    /** @type {FileItem} */ (/** @type {any} */ ({ id, name: '', mime_type: 'image/jpeg', created_at: 0, sort_date: 0, size_formatted: '' }))
            );
            const grid = this._container.querySelector('#person-photos');
            if (!grid) return;
            let html = '';
            fileIds.forEach((id, i) => {
                html += `<div class="photo-tile" data-idx="${i}"><img src="/api/files/${this._escAttr(id)}/thumbnail/preview" loading="lazy" decoding="async" alt=""></div>`;
            });
            grid.innerHTML = html;
            grid.querySelectorAll('.photo-tile').forEach((t) => {
                const el = /** @type {HTMLElement} */ (t);
                el.addEventListener('click', () => photosLightbox.open(items, Number(el.dataset.idx)));
            });
        } catch (err) {
            console.error('Person photos failed:', err);
        }
    },

    /**
     * @param {string} personId
     * @param {string} current
     */
    async _rename(personId, current) {
        const placeholder = i18n.t('people.unnamed');
        const value = current === placeholder ? '' : current;
        const name = await Modal.prompt({
            title: i18n.t('people.rename_title'),
            label: i18n.t('people.name_label'),
            value
        });
        if (name === null) return;
        try {
            await fetch(`/api/people/${personId}`, {
                method: 'PATCH',
                credentials: 'include',
                headers: { ...this._headers(), 'Content-Type': 'application/json' },
                body: JSON.stringify({ name: name || null })
            });
        } catch (err) {
            console.error('Rename failed:', err);
        }
        this._openPerson(personId, name || placeholder);
    },

    /** @param {string} text */
    _renderHint(text) {
        if (!this._container) return;
        this._container.innerHTML = `<div class="people-empty"><i class="fas fa-user-group"></i><p>${this._escHtml(text)}</p></div>`;
    },

    /** @param {any} s */
    _escHtml(s) {
        const d = document.createElement('div');
        d.textContent = s;
        return d.innerHTML;
    },

    /** @param {any} s */
    _escAttr(s) {
        return String(s || '')
            .replace(/"/g, '&quot;')
            .replace(/</g, '&lt;');
    }
};
