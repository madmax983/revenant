import { LightningElement, track, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getSchedules from '@salesforce/apex/WorkflowScheduleController.getSchedules';
import getScheduleDetail from '@salesforce/apex/WorkflowScheduleController.getScheduleDetail';
import getWorkflowDefinitions from '@salesforce/apex/WorkflowScheduleController.getWorkflowDefinitions';
import previewCron from '@salesforce/apex/WorkflowScheduleController.previewCron';
import saveSchedule from '@salesforce/apex/WorkflowScheduleController.saveSchedule';
import deleteSchedule from '@salesforce/apex/WorkflowScheduleController.deleteSchedule';
import enableSchedule from '@salesforce/apex/WorkflowScheduleController.enableSchedule';
import disableSchedule from '@salesforce/apex/WorkflowScheduleController.disableSchedule';
import runNow from '@salesforce/apex/WorkflowScheduleController.runNow';
import registerDedicatedJob from '@salesforce/apex/WorkflowScheduleController.registerDedicatedJob';
import unregisterDedicatedJob from '@salesforce/apex/WorkflowScheduleController.unregisterDedicatedJob';

const OVERLAP_OPTIONS = [
    { label: 'Skip (skip if prior run still active)', value: 'Skip' },
    { label: 'Allow (start regardless of prior runs)', value: 'Allow' }
];

const COLUMNS = [
    { label: 'Name', fieldName: 'Name', type: 'text', wrapText: false },
    { label: 'Workflow', fieldName: 'Workflow_Name__c', type: 'text' },
    { label: 'Cron', fieldName: 'Cron_Expression__c', type: 'text' },
    {
        label: 'Next Run',
        fieldName: 'nextFireTime',
        type: 'date',
        typeAttributes: {
            year: 'numeric',
            month: 'short',
            day: '2-digit',
            hour: '2-digit',
            minute: '2-digit'
        }
    },
    { label: 'Overlap', fieldName: 'Overlap_Policy__c', type: 'text', initialWidth: 90 },
    { label: 'Mode', fieldName: 'dedicatedLabel', type: 'text', initialWidth: 150 },
    { label: 'Status', fieldName: 'enabledLabel', type: 'text', initialWidth: 100 },
    { label: 'Last Outcome', fieldName: 'Last_Outcome__c', type: 'text', initialWidth: 120 },
    {
        label: 'Last Fired',
        fieldName: 'Last_Fired_Window__c',
        type: 'date',
        typeAttributes: {
            year: 'numeric',
            month: 'short',
            day: '2-digit',
            hour: '2-digit',
            minute: '2-digit'
        }
    },
    { type: 'action', typeAttributes: { rowActions: undefined } }
];

export default class WorkflowScheduleManager extends LightningElement {
    @track schedules = [];
    @track definitionOptions = [];
    overlapOptions = OVERLAP_OPTIONS;
    columns;

    constructor() {
        super();
        // Per-row action menus require a function reference; wire it up here so it
        // can read each row's precomputed rowActions array.
        const cols = COLUMNS.map((c) => ({ ...c }));
        cols[cols.length - 1] = {
            type: 'action',
            typeAttributes: { rowActions: this.getRowActions.bind(this) }
        };
        this.columns = cols;
    }

    getRowActions(row, doneCallback) {
        doneCallback(row.rowActions || []);
    }

    cacheBuster = '0';
    loading = false;
    _wiredSchedules;

    // Editor modal state
    editorOpen = false;
    @track form = {};
    cronPreview = { valid: null, lastFire: null, nextFire: null };
    saving = false;

    // Delete modal state
    deleteOpen = false;
    deleteTarget = null;

    // Logs modal state
    logsOpen = false;
    logsLoading = false;
    @track logs = [];
    logsScheduleName = '';

    @wire(getSchedules, { cacheBuster: '$cacheBuster' })
    wiredSchedules(result) {
        this._wiredSchedules = result;
        if (result.data) {
            this.schedules = result.data.map((s) => this.decorate(s));
        } else if (result.error) {
            this.toast('Error', this.errMsg(result.error), 'error');
        }
    }

    @wire(getWorkflowDefinitions)
    wiredDefinitions({ data, error }) {
        if (data) {
            this.definitionOptions = data.map((name) => ({
                label: name,
                value: name
            }));
        } else if (error) {
            // Non-fatal: editor combobox simply has no presets.
            this.definitionOptions = [];
        }
    }

    decorate(s) {
        const outcome = s.Last_Outcome__c;
        return {
            ...s,
            enabledVariant: s.Enabled__c ? 'success' : 'neutral',
            enabledLabel: s.Enabled__c ? 'Enabled' : 'Disabled',
            outcomeClass: this.badgeClass(outcome),
            dedicatedLabel: s.Dedicated_Slot__c
                ? s.dedicatedJobArmed
                    ? 'Dedicated (armed)'
                    : 'Dedicated (not armed)'
                : '0-slot',
            rowActions: this.buildRowActions(s)
        };
    }

    badgeClass(outcome) {
        if (outcome === 'Started') return 'badge badge-green';
        if (outcome === 'Skipped') return 'badge badge-orange';
        if (outcome === 'Deduped') return 'badge badge-blue';
        return 'badge badge-neutral';
    }

    buildRowActions(s) {
        const actions = [
            { label: 'Edit', name: 'edit' },
            { label: 'Run Now', name: 'runNow' },
            { label: 'View Logs', name: 'viewLogs' },
            {
                label: s.Enabled__c ? 'Disable' : 'Enable',
                name: 'toggleEnabled'
            }
        ];
        if (s.Dedicated_Slot__c) {
            actions.push(
                s.dedicatedJobArmed
                    ? { label: 'Abort Dedicated Job', name: 'abortDedicated' }
                    : { label: 'Arm Dedicated Job', name: 'armDedicated' }
            );
        }
        actions.push({ label: 'Delete', name: 'delete' });
        return actions;
    }

    get hasSchedules() {
        return this.schedules && this.schedules.length > 0;
    }

    // Held in JS rather than inline in the template: the LWC template compiler
    // treats `{...}` as a binding expression, so curly-brace example text must
    // not appear directly in markup.
    get inputJsonPlaceholder() {
        return '{"key":"value"} — supports {{fireTime}} and {{scheduleName}}';
    }

    get enabledCount() {
        return this.schedules.filter((s) => s.Enabled__c).length;
    }

    get dedicatedCount() {
        return this.schedules.filter((s) => s.Dedicated_Slot__c).length;
    }

    // ── List actions ─────────────────────────────────────────────────────────

    handleRefresh() {
        this.cacheBuster = String(Date.now());
        if (this._wiredSchedules) {
            refreshApex(this._wiredSchedules);
        }
    }

    handleRowAction(event) {
        const action = event.detail.action.name;
        const row = event.detail.row;
        switch (action) {
            case 'edit':
                this.openEditor(row);
                break;
            case 'delete':
                this.deleteTarget = row;
                this.deleteOpen = true;
                break;
            case 'runNow':
                this.doRunNow(row);
                break;
            case 'viewLogs':
                this.openLogs(row);
                break;
            case 'toggleEnabled':
                this.doToggleEnabled(row);
                break;
            case 'armDedicated':
                this.doArmDedicated(row, true);
                break;
            case 'abortDedicated':
                this.doArmDedicated(row, false);
                break;
            default:
                break;
        }
    }

    doRunNow(row) {
        runNow({ scheduleId: row.Id })
            .then((instanceId) => {
                this.toast(
                    'Run started',
                    `${row.Name} started instance ${instanceId}`,
                    'success'
                );
                this.handleRefresh();
            })
            .catch((e) => this.toast('Run failed', this.errMsg(e), 'error'));
    }

    doToggleEnabled(row) {
        const toggle = row.Enabled__c ? disableSchedule : enableSchedule;
        toggle({ scheduleId: row.Id })
            .then(() => {
                this.toast(
                    'Updated',
                    `${row.Name} ${row.Enabled__c ? 'disabled' : 'enabled'}`,
                    'success'
                );
                this.handleRefresh();
            })
            .catch((e) => this.toast('Error', this.errMsg(e), 'error'));
    }

    doArmDedicated(row, arm) {
        const op = arm ? registerDedicatedJob : unregisterDedicatedJob;
        op({ scheduleId: row.Id })
            .then(() => {
                this.toast(
                    'Updated',
                    `Dedicated job ${arm ? 'armed' : 'aborted'} for ${row.Name}`,
                    'success'
                );
                this.handleRefresh();
            })
            .catch((e) => this.toast('Error', this.errMsg(e), 'error'));
    }

    // ── Editor modal ───────────────────────────────────────────────────────────

    handleNew() {
        this.openEditor(null);
    }

    openEditor(row) {
        this.form = row
            ? {
                  Id: row.Id,
                  Name: row.Name,
                  Workflow_Name__c: row.Workflow_Name__c,
                  Cron_Expression__c: row.Cron_Expression__c,
                  Correlation_Key_Prefix__c: row.Correlation_Key_Prefix__c,
                  Input_Json__c: row.Input_Json__c,
                  Enabled__c: row.Enabled__c,
                  Overlap_Policy__c: row.Overlap_Policy__c || 'Skip',
                  Dedicated_Slot__c: row.Dedicated_Slot__c
              }
            : {
                  Id: null,
                  Name: '',
                  Workflow_Name__c: '',
                  Cron_Expression__c: '',
                  Correlation_Key_Prefix__c: '',
                  Input_Json__c: '',
                  Enabled__c: true,
                  Overlap_Policy__c: 'Skip',
                  Dedicated_Slot__c: false
              };
        this.cronPreview = { valid: null, lastFire: null, nextFire: null };
        this.editorOpen = true;
        if (this.form.Cron_Expression__c) {
            this.refreshCronPreview(this.form.Cron_Expression__c);
        }
    }

    closeEditor() {
        this.editorOpen = false;
    }

    handleFormChange(event) {
        const field = event.target.dataset.field;
        const value =
            event.target.type === 'checkbox'
                ? event.target.checked
                : event.detail
                ? event.detail.value
                : event.target.value;
        this.form = { ...this.form, [field]: value };
        if (field === 'Cron_Expression__c') {
            this.refreshCronPreview(value);
        }
    }

    refreshCronPreview(cron) {
        if (!cron) {
            this.cronPreview = { valid: null, lastFire: null, nextFire: null };
            return;
        }
        previewCron({ cron })
            .then((res) => {
                this.cronPreview = res;
            })
            .catch(() => {
                this.cronPreview = { valid: false, lastFire: null, nextFire: null };
            });
    }

    get cronValid() {
        return this.cronPreview && this.cronPreview.valid === true;
    }

    get cronInvalid() {
        return this.cronPreview && this.cronPreview.valid === false;
    }

    get saveDisabled() {
        return (
            this.saving ||
            !this.form.Name ||
            !this.form.Workflow_Name__c ||
            !this.form.Correlation_Key_Prefix__c ||
            this.cronInvalid
        );
    }

    handleSave() {
        this.saving = true;
        saveSchedule({ fields: { ...this.form } })
            .then(() => {
                this.toast('Saved', `${this.form.Name} saved`, 'success');
                this.editorOpen = false;
                this.saving = false;
                this.handleRefresh();
            })
            .catch((e) => {
                this.saving = false;
                this.toast('Save failed', this.errMsg(e), 'error');
            });
    }

    // ── Delete modal ───────────────────────────────────────────────────────────

    closeDelete() {
        this.deleteOpen = false;
        this.deleteTarget = null;
    }

    confirmDelete() {
        const target = this.deleteTarget;
        deleteSchedule({ scheduleId: target.Id })
            .then(() => {
                this.toast('Deleted', `${target.Name} deleted`, 'success');
                this.deleteOpen = false;
                this.deleteTarget = null;
                this.handleRefresh();
            })
            .catch((e) => this.toast('Delete failed', this.errMsg(e), 'error'));
    }

    // ── Logs modal ───────────────────────────────────────────────────────────

    openLogs(row) {
        this.logsScheduleName = row.Name;
        this.logsOpen = true;
        this.logsLoading = true;
        this.logs = [];
        getScheduleDetail({ scheduleId: row.Id })
            .then((res) => {
                this.logs = (res.logs || []).map((l) => ({
                    ...l,
                    outcomeClass: this.badgeClass(l.Outcome__c)
                }));
                this.logsLoading = false;
            })
            .catch((e) => {
                this.logsLoading = false;
                this.toast('Error', this.errMsg(e), 'error');
            });
    }

    closeLogs() {
        this.logsOpen = false;
        this.logs = [];
    }

    get hasLogs() {
        return this.logs && this.logs.length > 0;
    }

    // ── Utilities ───────────────────────────────────────────────────────────

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    errMsg(error) {
        if (error && error.body && error.body.message) {
            return error.body.message;
        }
        if (error && error.message) {
            return error.message;
        }
        return 'Unexpected error';
    }
}
