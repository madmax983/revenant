import { LightningElement, wire, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';

import getInstances from '@salesforce/apex/WorkflowDashboardController.getInstances';
import getInstanceDetails from '@salesforce/apex/WorkflowDashboardController.getInstanceDetails';
import getDefinitions from '@salesforce/apex/WorkflowDashboardController.getDefinitions';
import startWorkflow from '@salesforce/apex/WorkflowDashboardController.startWorkflow';
import retryWorkflowInstance from '@salesforce/apex/WorkflowDashboardController.retryWorkflowInstance';

export default class WorkflowDashboard extends LightningElement {
    @track instances = [];
    @track filteredInstances = [];
    @track definitions = [];
    @track stats = { total: 0, active: 0, completed: 0, failed: 0 };
    
    // UI state
    @track selectedInstanceId;
    @track selectedInst = {};
    @track steps = [];
    @track childInstances = [];
    @track loadingDetails = false;
    @track modalOpen = false;
    @track searchTerm = '';
    
    // Launch Modal Fields
    @track launchName = '';
    @track launchKey = '';
    @track launchInputJson = '';
    @track executingLaunch = false;
    @track launchError = '';

    wiredInstancesResult;
    wiredDefinitionsResult;

    @wire(getInstances)
    wiredInstances(result) {
        this.wiredInstancesResult = result;
        if (result.data) {
            this.instances = result.data.map(inst => {
                return {
                    ...inst,
                    formattedDate: this.formatDateTime(inst.CreatedDate),
                    listItemClass: `slds-p-around_small list-item clickable ${this.selectedInstanceId === inst.Id ? 'item-selected' : ''}`,
                    statusBadgeClass: this.getStatusBadgeClass(inst.Status__c)
                };
            });
            this.calculateStats();
            this.filterInstancesList();
            
            // Auto-refresh detail view if selected instance is currently loaded
            if (this.selectedInstanceId) {
                this.loadDetails(false);
            }
        } else if (result.error) {
            this.showToast('Error', 'Failed to retrieve workflow instances: ' + result.error.body.message, 'error');
        }
    }

    @wire(getDefinitions)
    wiredDefinitions(result) {
        this.wiredDefinitionsResult = result;
        if (result.data) {
            this.definitions = result.data;
        }
    }

    get definitionOptions() {
        return this.definitions.map(def => ({ label: def, value: def }));
    }

    get hasFilteredInstances() {
        return this.filteredInstances.length > 0;
    }

    get hasSteps() {
        return this.steps.length > 0;
    }

    get hasChildren() {
        return this.childInstances && this.childInstances.length > 0;
    }

    get isFailed() {
        return this.selectedInst && this.selectedInst.Status__c === 'Failed';
    }

    calculateStats() {
        const stats = { total: this.instances.length, active: 0, completed: 0, failed: 0 };
        this.instances.forEach(inst => {
            if (inst.Status__c === 'Pending' || inst.Status__c === 'Running' || inst.Status__c === 'Suspended') {
                stats.active += 1;
            } else if (inst.Status__c === 'Completed') {
                stats.completed += 1;
            } else if (inst.Status__c === 'Failed') {
                stats.failed += 1;
            }
        });
        this.stats = stats;
    }

    handleSearchChange(event) {
        this.searchTerm = event.target.value;
        this.filterInstancesList();
    }

    filterInstancesList() {
        if (!this.searchTerm) {
            this.filteredInstances = [...this.instances];
        } else {
            const term = this.searchTerm.toLowerCase();
            this.filteredInstances = this.instances.filter(inst => {
                return (
                    (inst.Name && inst.Name.toLowerCase().includes(term)) ||
                    (inst.Workflow_Name__c && inst.Workflow_Name__c.toLowerCase().includes(term)) ||
                    (inst.Correlation_Key__c && inst.Correlation_Key__c.toLowerCase().includes(term)) ||
                    (inst.Status__c && inst.Status__c.toLowerCase().includes(term))
                );
            });
        }
        // Update selected items classes
        this.filteredInstances = this.filteredInstances.map(inst => ({
            ...inst,
            listItemClass: `slds-p-around_small list-item clickable ${this.selectedInstanceId === inst.Id ? 'item-selected' : ''}`
        }));
    }

    handleSelectInstance(event) {
        this.selectedInstanceId = event.currentTarget.dataset.id;
        
        // Highlight in list
        this.instances = this.instances.map(inst => ({
            ...inst,
            listItemClass: `slds-p-around_small list-item clickable ${this.selectedInstanceId === inst.Id ? 'item-selected' : ''}`
        }));
        this.filterInstancesList();

        this.loadDetails(true);
    }

    handleSelectRelatedInstance(event) {
        this.selectedInstanceId = event.currentTarget.dataset.id;
        
        // Highlight in list
        this.instances = this.instances.map(inst => ({
            ...inst,
            listItemClass: `slds-p-around_small list-item clickable ${this.selectedInstanceId === inst.Id ? 'item-selected' : ''}`
        }));
        this.filterInstancesList();

        this.loadDetails(true);
    }

    loadDetails(showSpinner) {
        if (showSpinner) {
            this.loadingDetails = true;
        }
        getInstanceDetails({ instanceId: this.selectedInstanceId })
            .then(result => {
                const inst = result.instance;
                this.selectedInst = {
                    ...inst,
                    formattedDate: this.formatDateTime(inst.CreatedDate),
                    statusBadgeClass: this.getStatusBadgeClass(inst.Status__c),
                    Input__c: this.formatJson(inst.Input__c),
                    Output__c: this.formatJson(inst.Output__c)
                };

                // Map children
                this.childInstances = (result.children || []).map(child => {
                    return {
                        ...child,
                        formattedDate: this.formatDateTime(child.CreatedDate),
                        statusBadgeClass: this.getStatusBadgeClass(child.Status__c)
                    };
                });

                // Preserve showDetails toggle state if steps were already loaded
                const showDetailsMap = new Map();
                this.steps.forEach(s => showDetailsMap.set(s.Id, s.showDetails));

                this.steps = result.steps.map(step => {
                    return {
                        ...step,
                        formattedDate: this.formatDateTime(step.CreatedDate),
                        statusBadgeClass: this.getStatusBadgeClass(step.Status__c),
                        markerClass: this.getTimelineMarkerClass(step.Status__c),
                        showDetails: showDetailsMap.get(step.Id) || false,
                        Input__c: this.formatJson(step.Input__c),
                        Output__c: this.formatJson(step.Output__c)
                    };
                });
            })
            .catch(error => {
                this.showToast('Error', 'Failed to retrieve details: ' + error.body.message, 'error');
            })
            .finally(() => {
                this.loadingDetails = false;
            });
    }

    toggleStepDetails(event) {
        const stepId = event.currentTarget.dataset.stepId;
        this.steps = this.steps.map(step => {
            if (step.Id === stepId) {
                return { ...step, showDetails: !step.showDetails };
            }
            return step;
        });
    }

    handleRefresh() {
        refreshApex(this.wiredInstancesResult)
            .then(() => {
                this.showToast('Success', 'Workflow dashboard refreshed', 'success');
            });
    }

    handleOpenModal() {
        this.launchName = '';
        this.launchKey = '';
        this.launchInputJson = '';
        this.launchError = '';
        this.modalOpen = true;
    }

    handleCloseModal() {
        this.modalOpen = false;
    }

    handleLaunchFieldChange(event) {
        const fieldName = event.target.name;
        this[fieldName] = event.target.value;
    }

    handleExecuteWorkflow() {
        this.launchError = '';
        if (!this.launchName) {
            this.launchError = 'Please select a Workflow Definition.';
            return;
        }

        // Validate JSON if provided
        if (this.launchInputJson) {
            try {
                JSON.parse(this.launchInputJson);
            } catch (ex) {
                this.launchError = 'Input Payload must be a valid JSON string.';
                return;
            }
        }

        this.executingLaunch = true;
        startWorkflow({
            workflowName: this.launchName,
            correlationKey: this.launchKey,
            inputJson: this.launchInputJson
        })
            .then(result => {
                this.showToast('Success', 'Workflow instance started successfully. ID: ' + result, 'success');
                this.modalOpen = false;
                refreshApex(this.wiredInstancesResult);
            })
            .catch(error => {
                this.launchError = 'Failed to execute workflow: ' + error.body.message;
            })
            .finally(() => {
                this.executingLaunch = false;
            });
    }

    handleRetryWorkflow() {
        this.loadingDetails = true;
        retryWorkflowInstance({ instanceId: this.selectedInstanceId })
            .then(() => {
                this.showToast('Success', 'Workflow instance queued for retry successfully.', 'success');
                refreshApex(this.wiredInstancesResult);
                this.loadDetails(true);
            })
            .catch(error => {
                this.showToast('Error', 'Failed to retry workflow: ' + error.body.message, 'error');
            })
            .finally(() => {
                this.loadingDetails = false;
            });
    }

    // UTILITIES
    formatDateTime(dateStr) {
        if (!dateStr) return '';
        const d = new Date(dateStr);
        return d.toLocaleString();
    }

    formatJson(str) {
        if (!str) return '';
        try {
            const obj = JSON.parse(str);
            return JSON.stringify(obj, null, 2);
        } catch (ex) {
            return str; // Return raw string if not json
        }
    }

    getStatusBadgeClass(status) {
        switch (status) {
            case 'Completed':
                return 'badge badge-green';
            case 'Failed':
                return 'badge badge-red';
            case 'Suspended':
                return 'badge badge-orange';
            case 'Running':
                return 'badge badge-blue pulse-glow';
            case 'Pending':
                return 'badge badge-grey';
            case 'Retrying':
                return 'badge badge-yellow pulse-glow';
            default:
                return 'badge';
        }
    }

    getTimelineMarkerClass(status) {
        switch (status) {
            case 'Completed':
                return 'timeline-marker bg-green';
            case 'Failed':
                return 'timeline-marker bg-red';
            case 'Retrying':
                return 'timeline-marker bg-yellow';
            case 'Running':
                return 'timeline-marker bg-blue';
            case 'Pending':
                return 'timeline-marker bg-grey';
            default:
                return 'timeline-marker';
        }
    }

    showToast(title, message, variant) {
        this.dispatchEvent(
            new ShowToastEvent({
                title: title,
                message: message,
                variant: variant
            })
        );
    }
}
