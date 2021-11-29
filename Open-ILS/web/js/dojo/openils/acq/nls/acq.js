{
    "CREATE_PO_ASSETS_CONFIRM" : "This will create bibliographic, call number, and copy records for this purchase order in the ILS.\n\nContinue?",
    "ROLLBACK_PO_RECEIVE_CONFIRM" : "This will rollback receipt of all copies for this purchase order.\n\nContinue?",
    "ROLLBACK_LI_RECEIVE_CONFIRM" : "This will rollback receipt of selected line items from this purchase order.\n\nContinue?",
    "XUL_RECORD_DETAIL_PAGE" : "Record Details",
    "DELETE_LI_COPIES_CONFIRM" : "This will delete the last ${0} copies in the table.  Proceed?",
    "NO_PO_RESULTS" : "No results",
    "PO_HEADING_ERROR" : "Unexpected problem building virtual combined PO",
    "CONFIRM_SPLIT_PO" : "Are you sure you want to split this purchase order into\none purchase order for every constituent line item?",
    "DFA_NOT_ALL" : "Could not record all of your applications of distribution formulas.",
    "APPLY" : "Apply",
    "RESET_FORMULAE" : "Reset Formulas",
    "OUT_OF_COPIES" : "You have applied distribution formulas to every copy.",
    "ONE_LI_ATTR_SEARCH_AT_A_TIME" : "You cannot both type in an attribute value search and search for an uploaded file of terms at the same time.",
    "LI_ATTR_SEARCH_CHOOSE_FILE" : "Select file with search terms",
    "LI_ATTR_SEARCH_TOO_LARGE" : "That file is too large for this operation.",
    "SELECT_AN_LI_ATTRIBUTE" : "You must select an LI attribute.",
    "NO_RESULTS" : "No results.",
    "EXPORT_SAVE_DIALOG_TITLE" : "Save field values to a file",
    "EXPORT_SHORT_LIST" : "Not all of the selected items had the attribute '${0}'.\nChoose OK to save those values that could be found.",
    "EXPORT_EMPTY_LIST" : "No values for attribute '${0}' found.",
    "UNRECEIVE_LI" : "Are you sure you want to mark this lineitem as UN-received?",

    "UNRECEIVE_LID" : "Are you sure you want to mark this copy as UN-received?",
    "CONFIRM_LI_ALERT" : "An alert has been placed on the lineitem titled,\n\"${0}\":\n\n${1}\n${2}\n${3}\nChoose OK if you wish to acknowledge this alert.",
    "ALERT_UNSELECTED" : "You must choose an alert code.",
    "DFA_TIP" : "<strong>Applied by</strong>: ${0}<br /><strong>When</strong>: ${1}",
    "ITS_YOU" : "You",
    "JUST_NOW" : "Just now",
    "EXPLAIN_DFA_MGMT" : "Remove record of this distribution formula usage?",
    "VENDOR_PUBLIC" : "VENDOR PUBLIC",
    "PO_CANCEL_CONFIRM" : "Are you SURE you want to cancel this purchase order?",
    "LI_CANCEL_CONFIRM" : "Are you SURE you want to cancel this line item?",
    "LID_CANCEL_CONFIRM" : "Are you SURE you want to cancel this copy?",
    "UR_CANCEL_CONFIRM" : "Are you SURE you want to cancel this user request?",
    "UR_FILTER_USER" : "Enter barcode for user (or leave blank to unset the filter):",
    "UR_FILTER_LINEITEM" : "Enter id for lineitem (or leave blank to unset the filter):",
    "CANCEL_REASON" : "Cancel reason",
    "CANCEL" : "Cancel",
    "YES" : "Yes",
    "NO" : "No",
    "VENDOR_SAYS_PREPAY_NOT_NEEDED" : "The selected vendor does not necessarily require prepayment, according\nto records. Require prepayment on this PO anyway?",
    "VENDOR_SAYS_PREPAY_NEEDED" : "The selected vendor requires prepayment, according to records.\nProceed anyway without required prepayment on this PO?",
    "PREPAYMENT_REQUIRED_REMINDER" : "This PO requires prepayment.  Are you certain you're ready to activate it?",
    "LI_FORMAT_ERROR" : "Unexpected error retrieving formatted lineitem information.",
    "FUND_NOT_YET_LOADED" : "Fund not yet loaded. Try coming back to this display later.",
    "CONFIRM_DELETE_MAPPING" : "Are you sure you want to remove this tag from this fund?",
    "COULD_NOT_CREATE_MAPPING" : "Error tagging fund.",
    "COULD_NOT_DELETE_MAPPING" : "Error removing tag from fund.",
    "FUND_LIST_ROLLOVER_SUMMARY" : "Fund Propagation &amp; Rollover Summary for Fiscal Year ${0}",
    "FUND_LIST_ROLLOVER_SUMMARY_FUNDS" : "${1} funds propagated for fiscal year ${0} for the selected locations",
    "FUND_LIST_ROLLOVER_SUMMARY_ROLLOVER_AMOUNT" : "<b>$${1}</b> unspent money rolled over to fiscal year ${0} for the selected locations",
    "FUND_XFER_SAME_SOURCE_AND_DEST" : "Cannot transfer. The source and destination funds are the same.",
    "FUND_XFER_CONFIRM" : "Are you sure you're ready to commit this transfer?",
    "PO_ACTIVATED_ON" : "Activated ${0}",
    "PO_CHECKING" : "[One moment...]",
    "PO_COULD_ACTIVATE" : "Yes.",
    "PO_WARNING_NO_BLOCK_ACTIVATION" : "Yes; fund ${0} (${1}) would be encumbered beyond its warning level.",
    "PO_STOP_BLOCKS_ACTIVATION" : "No; fund ${0} (${1}) would be encumbered beyond its stop level.",
    "PO_ALREADY_ACTIVATED" : "Activated",
    "PO_FUND_WARNING_CONFIRM" : "Are you sure? Did you see the warning about over-encumbering a fund?",
    "CONFIRM_FUNDS_AT_STOP" : "One or more of the selected funds has a balance below its stop level.\nYou may not be able to activate purchase orders incorporating these copies.\nContinue?",
    "CONFIRM_FUNDS_AT_WARNING" : "One or more of the selected funds has a balance below its warning level.\nContinue?",
    "INVOICE_ITEM_DETAILS" : "${0} <br/> ${1} <br/> ${2}. <br/> Estimated Price: $${3}. <br/> Lineitem ID: ${4} <br/> PO: ${5} <br/> Order Date: ${6}",
    "INVOICE_CONFIRM_ITEM_DELETE" : "Remove this $${0} '${1}' charge from the invoice?",
    "INVOICE_CONFIRM_ENTRY_DETACH" : "Remove $${0} charge for item '${1}, ${2} [${3}] from the invoice?",
    "LINEITEM_SUMMARY" : "<div class='acq-lineitem-summary'><a target='_top' href='${19}'>${0}</a>, by ${1} (${2})</div>\n<div class='acq-lineitem-summary-extra'>\n${3} Ordered, ${4} Received, ${7} Invoiced, ${8} Claimed, ${9} Cancelled, ${23} Delayed</div>\n<div class='acq-lineitem-summary-extra'>Estimated $${6}, Encumbered $${16}, Paid $${17}</div>\n<div class='acq-lineitem-summary-extra'>\n# ${10} <a style='padding-right: 10px;' class='hidden${20}'  target='_top' href='/eg2/en-US/staff/acq/po/${12}#${10}'>&#x2318; ${13} ${18}</a>\n<a style='padding-right: 10px;' class='hidden${21}' target='_top' href='/eg2/en-US/staff/acq/picklist/${14}#${10}'>&#x2756; ${15}</a></div>",
    "INVOICE_CONFIRM_PRORATE" : "Prorate charges?\n\nAny subsequent changes to the invoice that would affect prorated amounts should be resolved manually.",
    "INVOICE_EXTRA_COPIES" : "You are attempting to invoice <b>${0}</b> more copies than originally ordered.  <br/><br/>To add these items to the original order, select a fund and choose 'Add New Items' below.  <br/>After saving the invoice, you may finish editing and importing the new copies from the lineitem details page.",
    "INVOICE_ITEM_PO_DETAILS" : "<b>${0}</b><br/><a target='_top' href='/eg2/en-US/staff/acq/po/${2}'>PO #${3} ${4}</a><br/>Total Estimated Cost: $${5}",
    "INVOICE_ITEM_PO_LABEL" : "<a target='_top' href='/eg2/en-US/staff/acq/po/${1}'>PO #${2} ${3}</a><br/>Total Estimated Cost: $${4}",
    "UNNAMED" : "Unnamed",
    "NO_FIND_INVOICE" : "Could not find that invoice.\nNote that the Invoice # field is case-sensitive.",
    "LI_BATCH_UPDATE": "Line item batch update",
    "NO_LI_TO_UPDATE" : "You have not selected any line items to update.",
    "NO_LI_TO_CLAIM" : "You have not selected any line items to claim.",
    "NO_LID_TO_CLAIM" : "You have not selected any line item details to claim.",
    "CHANGE_CLAIM_POLICY" : "Change claim policy",
    "CANCELED" : "Canceled",
    "RECVD" : "Recv'd",
    "NOT_RECVD" : "Not recv'd",
    "PRINT" : "Print",
    "INVOICES" : "Invoices",
    "NUM_CLAIMS_EXISTING" : "Claims (${0} existing)",
    "LOAD_TERMS_FIRST" : "You can't retrieve records until you've loaded a CSV file\nwith bibliographic IDs in the first column.",
    "SELECT_SEARCH_FIELD": "Select Search Field",
    "LIBRARY_INITIATED": "Library Initiated",
    "DEL_LI_FROM_PO": "That item has already been ordered!  Deleting it now will not revoke or modify any order that has been placed with a vendor.  Deleting the item may put the system's idea of your purchase order in a state that is inconsistent with reality.  Are you sure you mean to do this?",
    "ADD_LI_TO_PO_BAD_PO_STATE" : "The selected PO has already been activated",
    "ADD_LI_TO_PO_BAD_LI_STATE" : "The selected lineitem is not in a state that can be added to a purchase order",
    "INVOICE_NUMBER": "Invoice #${0}",
    "COPIES_TO_RECEIVE": "Number of copies to receive: ",
    "CREATE_PO_INVALID": "A purchase order must have an ordering agency and a provider.",
    "INVOICE_COPY_COUNT_INFO": "Copies received on this invoice: ${0} out of ${1}.",
    "INVOICE_IDENT_COLLIDE": "There is already an invoice in the system with the given combination of 'Vendor Invoice ID' and 'Provider,' which is not allowed.",
    "NEW_INVOICE": "New Invoice",
    "ACQ_SEARCH_CLASS_ABBR_jub": "LI",
    "ACQ_SEARCH_CLASS_ABBR_acqpl": "SL",
    "ACQ_SEARCH_CLASS_ABBR_acqpo": "PO",
    "ACQ_SEARCH_CLASS_ABBR_acqinv": "I",
    "ACQ_SEARCH_CLASS_ABBR_acqlid": "LID",
    "ACQ_SEARCH_CLASS_ABBR_acqlia": "LIA",
    "NO_LI_GENERAL" : "You have not selected any (suitable) line items.",
    "DUPE_PO_NAME_MSG" : "This name is already in use by another PO",
    "DUPE_PO_NAME_LINK" : "View PO",
    "PO_NAME_OPTIONAL" : "${0} (optional)",
    "FINALIZE_PO" : "Finalize this blanket PO?\nThis will disencumber all blanket charges and mark the PO as received",
    "LI_EXISTING_COPIES" : "There are ${0} existing copies for this bibliographic record at this location",
    "LI_CREATING_ASSETS" : "Creating bib, call number, and copy records...",
    "PO_ACTIVATING" : "Activating purchase order...",
    "ACTIVATE_LI_PROCESSED"             : "Lineitems Processed: ${0}",
    "ACTIVATE_VQBR_PROCESSED"           : "Vandelay Records Processed: ${0}",
    "ACTIVATE_BIBS_PROCESSED"           : "Bib Records Merged/Imported: ${0}",
    "ACTIVATE_LID_PROCESSED"            : "ACQ Copies Processed: ${0}",
    "ACTIVATE_DEBITS_ACCRUED_PROCESSED" : "Debits Encumbered: ${0}",
    "ACTIVATE_COPIES_PROCESSED"         : "Real Copies Processed: ${0}"
}
