import { LightningElement, wire, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getFilteredInstances from '@salesforce/apex/WorkflowDashboardController.getFilteredInstances';
import getWorkflowStats from '@salesforce/apex/WorkflowDashboardController.getWorkflowStats';
import getInstanceDetails from '@salesforce/apex/WorkflowDashboardController.getInstanceDetails';
import getDefinitions from '@salesforce/apex/WorkflowDashboardController.getDefinitions';
import startWorkflow from '@salesforce/apex/WorkflowDashboardController.startWorkflow';
import retryWorkflowInstance from '@salesforce/apex/WorkflowDashboardController.retryWorkflowInstance';
import cancelWorkflow from '@salesforce/apex/WorkflowDashboardController.cancelWorkflow';
import submitApproval from '@salesforce/apex/WorkflowDashboardController.submitApproval';

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
    @track successor = null;
    @track approvalComments = '';
    @track modalOpen = false;
    @track searchTerm = '';
    
    // Launch Modal Fields
    @track launchName = '';
    @track launchKey = '';
    @track launchInputJson = '';
    @track executingLaunch = false;
    @track launchError = '';

    // Pagination & Filters State
    @track selectedWorkflow = '';
    @track selectedStatus = '';
    @track limitSize = 50;
    @track offsetSize = 0;
    @track hasMore = true;
    @track loadingMore = false;

    wiredDefinitionsResult;
    pollingInterval;
    autoRefreshInterval;
    searchTimeout;

    connectedCallback() {
        this.fetchInstances(false);
        this.startAutoRefresh();
    }

    disconnectedCallback() {
        this.stopPolling();
        this.stopAutoRefresh();
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

    get workflowOptions() {
        const options = [{ label: '-- All Definitions --', value: '' }];
        if (this.definitions) {
            this.definitions.forEach(def => {
                options.push({ label: def, value: def });
            });
        }
        return options;
    }

    get statusOptions() {
        return [
            { label: '-- All Statuses --', value: '' },
            { label: 'Running', value: 'Running' },
            { label: 'Pending', value: 'Pending' },
            { label: 'Suspended', value: 'Suspended' },
            { label: 'Retrying', value: 'Retrying' },
            { label: 'Compensating', value: 'Compensating' },
            { label: 'Compensated', value: 'Compensated' },
            { label: 'Completed', value: 'Completed' },
            { label: 'Failed', value: 'Failed' },
            { label: 'Cancelling', value: 'Cancelling' },
            { label: 'Cancelled', value: 'Cancelled' },
            { label: 'ContinuedAsNew', value: 'ContinuedAsNew' }
        ];
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

    get isCancelable() {
        if (!this.selectedInst) return false;
        const status = this.selectedInst.Status__c;
        return status === 'Pending' || status === 'Running' || status === 'Suspended';
    }

    fetchInstances(isAppend) {
        if (!isAppend) {
            this.offsetSize = 0;
            this.hasMore = true;
            this.loadingMore = false;
        }
        
        const currentOffset = this.offsetSize;
        const currentLimit = this.limitSize;
        
        if (isAppend) {
            this.loadingMore = true;
        } else {
            this.loadingDetails = true;
        }
        
        const instancesPromise = getFilteredInstances({
            workflowName: this.selectedWorkflow,
            status: this.selectedStatus,
            searchTerm: this.searchTerm,
            limitSize: currentLimit,
            offsetSize: currentOffset
        });

        const statsPromise = getWorkflowStats({
            workflowName: this.selectedWorkflow,
            status: this.selectedStatus,
            searchTerm: this.searchTerm
        });
        
        return Promise.all([instancesPromise, statsPromise])
        .then(([result, statsResult]) => {
            const formatted = result.map(inst => {
                return {
                    ...inst,
                    formattedDate: this.formatDateTime(inst.CreatedDate),
                    listItemClass: `slds-p-around_small list-item clickable ${this.selectedInstanceId === inst.Id ? 'item-selected' : ''}`,
                    statusBadgeClass: this.getStatusBadgeClass(inst.Status__c)
                };
            });
            
            if (isAppend) {
                this.instances = [...this.instances, ...formatted];
            } else {
                this.instances = formatted;
            }
            
            // Guard against SOQL 2000 offset limit
            if (result.length < currentLimit || (this.offsetSize + result.length) >= 2000) {
                this.hasMore = false;
            } else {
                this.hasMore = true;
            }
            
            this.stats = statsResult;
            this.filterInstancesList();
            
            // Auto-refresh detail view if selected instance is currently loaded
            if (this.selectedInstanceId && !isAppend) {
                this.loadDetails(false);
            }
        })
        .catch(error => {
            this.showToast('Error', 'Failed to retrieve workflow instances: ' + (error.body ? error.body.message : error.message), 'error');
        })
        .finally(() => {
            this.loadingMore = false;
            this.loadingDetails = false;
        });
    }

    refreshInstances() {
        const currentSize = this.instances.length > 0 ? this.instances.length : this.limitSize;
        
        const instancesPromise = getFilteredInstances({
            workflowName: this.selectedWorkflow,
            status: this.selectedStatus,
            searchTerm: this.searchTerm,
            limitSize: currentSize,
            offsetSize: 0
        });

        const statsPromise = getWorkflowStats({
            workflowName: this.selectedWorkflow,
            status: this.selectedStatus,
            searchTerm: this.searchTerm
        });

        return Promise.all([instancesPromise, statsPromise])
        .then(([result, statsResult]) => {
            this.instances = result.map(inst => {
                return {
                    ...inst,
                    formattedDate: this.formatDateTime(inst.CreatedDate),
                    listItemClass: `slds-p-around_small list-item clickable ${this.selectedInstanceId === inst.Id ? 'item-selected' : ''}`,
                    statusBadgeClass: this.getStatusBadgeClass(inst.Status__c)
                };
            });
            this.stats = statsResult;
            this.filterInstancesList();
            
            if (this.selectedInstanceId) {
                this.loadDetails(false);
            }
        })
        .catch(error => {
            console.error('Error refreshing instances:', error);
        });
    }

    handleSearchChange(event) {
        this.searchTerm = event.target.value;
        if (this.searchTimeout) {
            clearTimeout(this.searchTimeout);
        }
        this.searchTimeout = setTimeout(() => {
            this.fetchInstances(false);
        }, 300);
    }

    handleWorkflowFilterChange(event) {
        this.selectedWorkflow = event.target.value;
        this.fetchInstances(false);
    }

    handleStatusFilterChange(event) {
        this.selectedStatus = event.target.value;
        this.fetchInstances(false);
    }

    filterInstancesList() {
        this.filteredInstances = this.instances.map(inst => ({
            ...inst,
            listItemClass: `slds-p-around_small list-item clickable ${this.selectedInstanceId === inst.Id ? 'item-selected' : ''}`
        }));
    }

    handleScroll(event) {
        const container = event.target;
        const threshold = 20;
        const isNearBottom = container.scrollHeight - container.scrollTop - container.clientHeight <= threshold;
        
        if (isNearBottom && !this.loadingMore && this.hasMore) {
            this.loadMoreInstances();
        }
    }

    loadMoreInstances() {
        if (this.loadingMore || !this.hasMore) {
            return;
        }
        this.offsetSize += this.limitSize;
        this.fetchInstances(true);
    }

    handleSelectInstance(event) {
        this.stopPolling();
        this.selectedInstanceId = event.currentTarget.dataset.id;
        this.filterInstancesList();
        this.loadDetails(true);
    }

    handleSelectRelatedInstance(event) {
        this.stopPolling();
        this.selectedInstanceId = event.currentTarget.dataset.id;
        this.filterInstancesList();
        this.loadDetails(true);
    }

    loadDetails(showSpinner) {
        if (showSpinner) {
            this.loadingDetails = true;
        }
        this.successor = null;
        getInstanceDetails({ instanceId: this.selectedInstanceId })
            .then(result => {
                const inst = result.instance;
                this.successor = result.successor;
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
                    let approvalInfo = null;
                    let childWorkflowLink = null;
                    if (step.Output__c) {
                        try {
                            const parsed = JSON.parse(step.Output__c);
                            if (parsed.waitingForApproval) {
                                approvalInfo = {
                                    key: parsed.approvalKey,
                                    role: parsed.approvalRole
                                };
                            }
                            if (parsed.childWorkflowName && parsed.childCorrelationKey) {
                                const matchingChild = this.childInstances.find(
                                    child => child.Correlation_Key__c === parsed.childCorrelationKey && child.Workflow_Name__c === parsed.childWorkflowName
                                );
                                if (matchingChild) {
                                    childWorkflowLink = {
                                        id: matchingChild.Id,
                                        name: matchingChild.Name
                                    };
                                }
                            }
                        } catch (e) {
                            // ignore non-json
                        }
                    }

                    return {
                        ...step,
                        formattedDate: this.formatDateTime(step.CreatedDate),
                        statusBadgeClass: approvalInfo ? 'badge badge-orange pulse-glow' : this.getStatusBadgeClass(step.Status__c),
                        markerClass: approvalInfo ? 'timeline-marker bg-yellow pulse-glow' : this.getTimelineMarkerClass(step.Status__c),
                        showDetails: showDetailsMap.get(step.Id) || (approvalInfo ? true : false),
                        isWaitingForApproval: !!approvalInfo,
                        approvalKey: approvalInfo ? approvalInfo.key : null,
                        approvalRole: approvalInfo ? approvalInfo.role : null,
                        childInstanceId: childWorkflowLink ? childWorkflowLink.id : null,
                        childInstanceName: childWorkflowLink ? childWorkflowLink.name : null,
                        Input__c: this.formatJson(step.Input__c),
                        Output__c: this.formatJson(step.Output__c)
                    };
                });

                // Check if we can stop polling early
                const isStillWaitingForApproval = this.steps.some(step => step.isWaitingForApproval);
                const isTransitioning = inst.Status__c === 'Running' || inst.Status__c === 'Compensating' || inst.Status__c === 'Cancelling';
                if (!isStillWaitingForApproval && !isTransitioning) {
                    this.stopPolling();
                }
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
        this.refreshInstances()
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
                this.refreshInstances();
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
                this.refreshInstances();
                this.loadDetails(true);
                this.startPolling();
            })
            .catch(error => {
                this.showToast('Error', 'Failed to retry workflow: ' + error.body.message, 'error');
            })
            .finally(() => {
                this.loadingDetails = false;
            });
    }

    handleCancelWorkflow() {
        const runCompensate = confirm('Cancel this workflow? Click OK to run Saga compensations and roll back completed steps, or Cancel to abort immediately without compensations.');
        
        this.loadingDetails = true;
        cancelWorkflow({ 
            instanceId: this.selectedInstanceId, 
            runCompensations: runCompensate 
        })
            .then(() => {
                this.showToast('Success', 'Workflow cancellation requested successfully.', 'success');
                this.refreshInstances();
                this.loadDetails(true);
                this.startPolling();
            })
            .catch(error => {
                this.showToast('Error', 'Failed to cancel workflow: ' + (error.body ? error.body.message : error.message), 'error');
            })
            .finally(() => {
                this.loadingDetails = false;
            });
    }

    handleCommentsChange(event) {
        this.approvalComments = event.target.value;
    }

    handleApprovalSubmit(event) {
        const approvalKey = event.target.dataset.key;
        const approved = event.target.dataset.approved === 'true';
        
        this.loadingDetails = true;
        submitApproval({
            instanceId: this.selectedInstanceId,
            approvalKey: approvalKey,
            approved: approved,
            comments: this.approvalComments
        })
            .then(() => {
                this.showToast('Success', `Approval decision (${approved ? 'Approve' : 'Reject'}) submitted successfully.`, 'success');
                this.approvalComments = '';
                this.refreshInstances();
                this.loadDetails(true);
                this.startPolling();
            })
            .catch(error => {
                this.showToast('Error', 'Failed to submit approval: ' + error.body.message, 'error');
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
            case 'ContinuedAsNew':
                return 'badge badge-blue';
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
            case 'Compensating':
                return 'badge badge-yellow pulse-glow';
            case 'Compensated':
                return 'badge badge-orange';
            case 'Cancelling':
                return 'badge badge-yellow pulse-glow';
            case 'Cancelled':
                return 'badge badge-grey';
            default:
                return 'badge';
        }
    }

    getTimelineMarkerClass(status) {
        switch (status) {
            case 'Completed':
                return 'timeline-marker bg-green';
            case 'ContinuedAsNew':
                return 'timeline-marker bg-blue';
            case 'Failed':
                return 'timeline-marker bg-red';
            case 'Retrying':
                return 'timeline-marker bg-yellow';
            case 'Running':
                return 'timeline-marker bg-blue';
            case 'Pending':
                return 'timeline-marker bg-grey';
            case 'Compensating':
                return 'timeline-marker bg-yellow';
            case 'Compensated':
                return 'timeline-marker bg-orange';
            case 'Cancelling':
                return 'timeline-marker bg-yellow';
            case 'Cancelled':
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

    startPolling() {
        this.stopPolling();
        let attempts = 0;
        this.pollingInterval = setInterval(() => {
            attempts += 1;
            this.refreshInstances();
            if (attempts >= 10) {
                this.stopPolling();
            }
        }, 2000);
    }

    stopPolling() {
        if (this.pollingInterval) {
            clearInterval(this.pollingInterval);
            this.pollingInterval = null;
        }
    }

    startAutoRefresh() {
        this.stopAutoRefresh();
        this.autoRefreshInterval = setInterval(() => {
            this.refreshInstances();
        }, 5000);
    }

    stopAutoRefresh() {
        if (this.autoRefreshInterval) {
            clearInterval(this.autoRefreshInterval);
            this.autoRefreshInterval = null;
        }
    }
}
